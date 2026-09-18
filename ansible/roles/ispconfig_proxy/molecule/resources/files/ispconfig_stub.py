#!/usr/bin/env python3
"""A stand-in for the ISPConfig 3 JSON remote API, for the molecule scenarios.

It answers the handful of methods the ispconfig_proxy role calls, the way
ISPConfig 3.2/3.3 answers them (read from interface/lib/classes/remoting*.php
and remote.d/sites.inc.php of the 3.3.2 tarball):

  - the method is the query string (?login, ?sites_web_domain_get, ...)
  - the body is a JSON object with the method's parameters by name
  - every answer is HTTP 200 with {"code", "message", "response"}; "ok" on
    success, "remote_fault" with the message of the SoapFault otherwise
  - sites_web_domain_get with an object as primary_id filters web_domain by
    equality on every key and returns a list; with an integer it returns the
    record itself (or false)
  - sites_web_domain_update merges the old record with the params (and resets
    an empty pm_max_children to 10, as the real one does), returns 1
  - sites_web_aliasdomain_add inserts a web_domain row, returns its id
  - sites_web_aliasdomain_delete removes the row, returns 1
  - a domain that exists already is refused with ISPConfig's own message

State lives in a JSON file (--state), so that verify can read it: the rows,
and a counter per method, which is how a scenario proves that a re-run did not
call add again.
"""
import argparse
import json
import os
import secrets
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

DUPLICATE = "There is already a website or sub / aliasdomain with this domain name."
BAD_SESSION = "The Session is expired or does not exist."
BAD_LOGIN = "The login failed. Username or password wrong."


class Fault(Exception):
    def __init__(self, message, code="remote_fault"):
        super().__init__(message)
        self.code = code


class State:
    def __init__(self, path):
        self.path = path
        self.data = {"next_id": 1, "records": [], "sessions": [], "calls": {}}
        if os.path.exists(path):
            with open(path) as f:
                self.data = json.load(f)

    def save(self):
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.data, f, indent=2, sort_keys=True)
        os.replace(tmp, self.path)

    def count(self, method):
        self.data["calls"][method] = self.data["calls"].get(method, 0) + 1


class Api:
    def __init__(self, state, username, password):
        self.state = state
        self.username = username
        self.password = password

    # -- helpers ---------------------------------------------------------
    def _check_session(self, params):
        if params.get("session_id") not in self.state.data["sessions"]:
            raise Fault(BAD_SESSION)

    def _records(self):
        return self.state.data["records"]

    def _find(self, primary_id):
        if isinstance(primary_id, dict):
            return [
                r
                for r in self._records()
                if all(str(r.get(k, "")) == str(v) for k, v in primary_id.items())
            ]
        if isinstance(primary_id, (int, str)) and str(primary_id).lstrip("-").isdigit():
            pid = int(primary_id)
            if pid == -1:
                return list(self._records())
            if pid < 1:
                raise Fault("The ID has to be > 0 or -1.")
            for r in self._records():
                if r["domain_id"] == pid:
                    return r
            return False
        raise Fault("The ID must be either an integer or an array.")

    def _insert(self, params, defaults):
        domain = str(params.get("domain", "")).lower()
        if not domain:
            raise Fault("Domain name invalid.")
        if any(r["domain"] == domain for r in self._records()):
            raise Fault(DUPLICATE)
        rec = dict(defaults)
        rec.update({k: v for k, v in params.items()})
        rec["domain"] = domain
        rec["domain_id"] = self.state.data["next_id"]
        self.state.data["next_id"] += 1
        self._records().append(rec)
        return rec["domain_id"]

    # -- methods ---------------------------------------------------------
    def login(self, p):
        if not p.get("username"):
            raise Fault("The login username is empty.", "login_username_empty")
        if p.get("username") != self.username or p.get("password") != self.password:
            raise Fault(BAD_LOGIN)
        sid = "m" + secrets.token_hex(20)
        self.state.data["sessions"].append(sid)
        return sid

    def logout(self, p):
        sid = p.get("session_id")
        if not sid:
            raise Fault("The SessionID is empty.")
        if sid in self.state.data["sessions"]:
            self.state.data["sessions"].remove(sid)
            return True
        return False

    def sites_web_domain_get(self, p):
        self._check_session(p)
        return self._find(p.get("primary_id"))

    def sites_web_domain_add(self, p):
        self._check_session(p)
        params = dict(p.get("params") or {})
        defaults = {
            "type": "vhost",
            "parent_domain_id": "0",
            "active": "y",
            "subdomain": "none",
            "apache_directives": "",
            "ssl_letsencrypt": "n",
            "pm_max_children": "10",
        }
        if params.get("vhost_type", "") == "":
            params["vhost_type"] = "name"
        if params.get("ip_address", "") == "":
            params["ip_address"] = "*"
        return self._insert(params, defaults)

    def sites_web_domain_update(self, p):
        self._check_session(p)
        rec = self._find(p.get("primary_id"))
        if not isinstance(rec, dict):
            raise Fault("The ID has to be > 0.")
        params = dict(p.get("params") or {})
        # sites_web_domain_update resets empty pm_* values before the merge.
        if params.get("pm_max_children", "") == "":
            params["pm_max_children"] = "10"
        rec.update(params)
        return 1

    def sites_web_aliasdomain_add(self, p):
        self._check_session(p)
        params = dict(p.get("params") or {})
        defaults = {"active": "y", "subdomain": "none", "ssl_letsencrypt_exclude": "n"}
        return self._insert(params, defaults)

    def sites_web_aliasdomain_delete(self, p):
        self._check_session(p)
        pid = int(p.get("primary_id") or 0)
        if pid < 1:
            raise Fault("The ID has to be > 0.", "invalid_id")
        before = len(self._records())
        self.state.data["records"] = [r for r in self._records() if r["domain_id"] != pid]
        return before - len(self._records())


class Handler(BaseHTTPRequestHandler):
    api = None
    state = None

    def _reply(self, code, message, response=False):
        body = json.dumps({"code": code, "message": message, "response": response}).encode()
        self.send_response(200)
        self.send_header("Content-Type", 'application/json; charset="utf-8"')
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        query = urlparse(self.path).query
        method = query.split("&")[0].split("=")[0] if query else ""
        if not method:
            return self._reply("invalid_method", "Method not provided in json call")
        length = int(self.headers.get("Content-Length") or 0)
        try:
            params = json.loads(self.rfile.read(length) or b"")
        except ValueError:
            params = None
        if not isinstance(params, dict):
            return self._reply("invalid_data", "The JSON data sent to the api is invalid")
        func = getattr(self.api, method, None)
        if func is None or method.startswith("_"):
            return self._reply("invalid_method", "Method %s does not exist" % method)
        self.state.count(method)
        try:
            result = func(params)
        except Fault as fault:
            self.state.save()
            return self._reply("remote_fault", str(fault))
        self.state.save()
        return self._reply("ok", "", result)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--state", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--password", required=True)
    args = parser.parse_args()
    Handler.state = State(args.state)
    Handler.api = Api(Handler.state, args.username, args.password)
    HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
