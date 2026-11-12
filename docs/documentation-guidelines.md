# Documentation guidelines

## Write clearly

- Use active voice. Name the actor and the action. For example, write “The
  editor cancels the scan when you change the query.”
- Give each sentence one main point and each paragraph one subject. Aim for at
  most 20 words in an instruction and 25 in a descriptive sentence. Preserve
  technical meaning when a sentence needs more words.
- Use one term for each concept. Keep the exact spelling and case of commands,
  keys, paths, field names, and messages. Format those literals as code.
- Name the subject of a reference section, such as “Cache and file limits.”
  Name the task in a procedure, such as “Open a workspace.”

## Write procedures

- State prerequisites before the steps. Include any required mode, directory,
  or tool version.
- Number steps when order matters. Start each step with an action verb.
  Give one action per step unless the actions must happen together.
- Put consequential effects and stop conditions next to the step they apply
  to. Give the expected result and how to check it. For example, after a
  workspace write, check the message for how many files Tome wrote.

## Describe system behavior

- Start with the system's purpose and the state it owns. Describe the supported
  commands or keys, what they read or change, and what result the reader gets.
- State each limit with its unit and scope. For example, “Tome opens regular
  files up to 64 MiB.” Define what counts and timers include. Name the operation
  that each error describes.
- Describe what happens on failure. Say what changed and what state the system
  keeps. Give recovery steps when the reader can take them.

## Keep one place for each explanation

- Put the full explanation in the reference for the system that owns the
  behavior. Link to it from other pages. Keep the README as a documentation
  index.
- Use the [source layout](source-layout.md) to show how the systems fit together
  and link to their references.
- Update the owning reference when behavior changes. Keep supported limits
  and recovery details current. Remove obsolete behavior and duplicate text.

These writing rules draw on
[ASD Simplified Technical English, Issue 9](https://www.asd-ste100.org/assets/files/ASD-STE100_ISSUE9.pdf).
