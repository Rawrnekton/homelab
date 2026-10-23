# Contributing

## Comments

These rules apply to all files in this repository: Ansible, Jinja templates,
cloud-init, shell scripts and molecule scenarios.

1. **Write a comment only for data that the code cannot show.** This is a
   reason, a trap, a constraint, an order that is important, or a source (a link
   or an error text). Do not write what the task name or the code already tells.
2. **Give the reason that applies now.** Do not tell the history ("the former
   role", "this was changed because"). The history goes into the commit message.
3. **Put the comment above the item that it explains.** A comment at the end of
   a line is permitted only in a short list of values.
4. **Keep each fact in one place.** The documentation of a variable goes into
   `meta/argument_specs.yml` and the `README.md` of the role.
   `defaults/main.yml` contains only the real defaults.
5. **Copy an error message word for word,** in quotes, so that `grep` can find
   it.
6. **Write in ASD-STE100 (Simplified Technical English).**
   - Use a maximum of 20 words in an instruction and 25 words in a description.
   - Write about one topic in each sentence.
   - Use the active voice.
   - Do not use "-ing" forms, except in technical names.
   - Use the approved words with their approved meaning. For example, write
     "show", not "display", and "make sure", not "ensure".
   - Start each sentence with a capital letter and stop it with a full stop.
   - Technical names and identifiers (`k3s`, `delegate_to`, `pvresize`) stay as
     they are.
7. **Use section banners only in a file of more than approximately 50 lines.**
   Use the same format for all banners in a file.
8. **Do not keep a `TODO` or code that is commented out.** An open point goes
   into the backlog.
9. **Try to keep a comment to 3 lines or less.** A longer comment is correct
   when the reason needs the space, for example a trap that cost hours to find.
   Then the first sentence gives the short answer, and the subsequent sentences
   give the details.
