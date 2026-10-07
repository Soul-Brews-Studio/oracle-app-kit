# oracle-fb bridge

Facebook thread ↔ oracle, through the Chrome extension. 127.0.0.1 only.

```
 FORWARD   extension ─POST /thread─► ~/.oracle-fb/threads/<id>.md|json ─► app draft (thread=<id>)
 BACK      fbreply ─POST /reply─► bridge ─WebSocket─► extension ─► types into that comment's box
                                                                   (a human presses Enter)
```

Run it (a long job — put it in a herdr pane):

    bun /opt/Code/github.com/Soul-Brews-Studio/oracle-app-kit/browser/bridge/server.ts

Reply to a comment (ids come from the thread file / `--list`):

    bun fbreply.ts --status                      # which browsers are connected or not (+ extension version)
    bun fbreply.ts --list
    bun fbreply.ts --tabs                        # every Facebook tab, in every connected browser (id per browser)
    bun fbreply.ts <thread> c2 "your reply"      # goes back to the tab the thread was forwarded from
    bun fbreply.ts --to Chrome/153 --tab 123 <thread> c2 "…"   # a specific browser / tab

Who may talk: the extension (Origin `chrome-extension://<id>`) on `/ws` and `/thread`; the CLI (`x-fb-token`, token in
`~/.oracle-fb/token`) on `/reply` and `/threads`. A web page has neither. Nothing here ever submits a comment.

Env: `ORACLE_FB_PORT` (4747), `ORACLE_FB_EXT` (extension id).
