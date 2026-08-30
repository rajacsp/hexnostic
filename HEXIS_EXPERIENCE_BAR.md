# The Hexis Experience Bar

The standard every user-facing change is checked against. A change isn't done
until it passes every principle that applies. This is not aspirational — it's the
definition of "done." Each principle is followed by its test and the real failure
it was learned from.

---

### 1. Derive from truth — never hardcode
Never hardcode a value that has a live source: models, defaults, capabilities,
versions, endpoints. Read the source, cache it, fall back sensibly.
**Test:** scan the diff for literals that should be lookups.
*(Learned from: a stale `gpt-4o` default for every provider.)*

### 2. The user keeps control
No destructive or irreversible action on a timer, by default, or without an
explicit choice. No auto-exit, no auto-overwrite of user data, no silent
deletion. Timers may *inform*, never *decide*.
**Test:** does anything happen *to* the user rather than *by* them?
*(Learned from: the consent screen that dumped you to the shell on a countdown.)*

### 3. Honor the medium
In a terminal: Ctrl+C exits, copy/paste and scrollback are native, keyboard-first,
no mouse or focus-hunting required. In a browser: it's a browser. Don't fight the
platform's conventions — if a framework's defaults require constant overriding,
the framework is wrong for the job.
**Test:** does the user have to learn *this program's* idioms for things the
medium already defines?
*(Learned from: a full-screen Textual TUI that captured the mouse and rebound Ctrl+C to "copy.")*

### 4. No dead-ends
Every flow completes in place or hands the user the exact next step. Never "quit,
run this other command, then come back." Errors state what happened, why, and the
one thing to do next.
**Test:** at every branch, is there always a way forward from here?
*(Learned from: a setup wizard that told you to open a terminal and run a login command.)*

### 5. Least surprise
Never silently reuse ambient state the user didn't choose — env credentials, other
tools' logins, stale config. Own your own state. When you *detect* something
ambient, surface it; don't consume it.
**Test:** would the user be surprised to learn where this value came from?
*(Learned from: silently reusing a stale Claude Code credential.)*

### 6. Defaults are the expert's choice
The default is what a knowledgeable user would pick, not the first constant that
compiles. Defaults are a feature, not a placeholder.
**Test:** would someone who knows this domain accept the default without changing it?

### 7. Whole journey, not the diff
"Done" means the end-to-end experience holds — pick the option, complete the flow,
see the result — not "the line compiles / the test passes." Drive the real path
before calling it done.
**Test:** did I actually run the thing a user runs, start to finish?
*(Learned from: shipping locally-correct changes that broke the journey one level up.)*

### 8. Fail loud, recover gracefully
Advisory checks never block (a bad key surfaces with a clear message, not a wall).
Real failures show the cause and the fix — never a bare traceback, never a silent
`except: pass`.
**Test:** on the worst input, does the user get a sentence they can act on?

---

See also `why_i_suck_and_how_to_fix_it.md` — the altitude failure that let these
slip through one at a time instead of being caught as a class.
