# Handoffs

This repository's continuity index: the file `/pickup` reads first to decide what to resume.
`/handoff` writes a resume note to `docs/handoffs/<YYYY-MM-DD>.md` and adds its row here;
`/pickup` resumes the newest **open** row and marks it **resumed**. Keep the table as it is:
the handoff plugin's script edits it.

Status: `open` (waiting to be resumed) · `resumed` (a `/pickup` took it) · `superseded` (a newer
note replaced it).

## Handoff notes

Newest first.

| Date | File | Status | Next action |
| ---- | ---- | ------ | ----------- |
