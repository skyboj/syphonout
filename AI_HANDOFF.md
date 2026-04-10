# AI Handoff Protocol

## Current Agent (Work Rules):
1. **Atomicity:** Every logical change (new feature, bug fix, refactoring) must end with a commit.
2. **Logging:** To save progress, use the command: `bash step.sh "Description of what was done"`.
3. **State File:** Before ending the session, ensure `.ai_session_log.md` contains up-to-date information on exactly where you stopped and what the immediate next steps are.

## New Agent (Resume Rules):
When starting a new session, follow these steps:
1. **Analyze History:** Read the last 5 commits: `git log -n 5`.
2. **Read Log:** Review the `.ai_session_log.md` file to understand the current state, recent tasks, and any roadblocks.
3. **Check Changes:** Review recent code modifications via `git diff HEAD~1`.
4. **Plan:** Formulate a task list for the current session based on the latest entries and "Next Steps" in the log.