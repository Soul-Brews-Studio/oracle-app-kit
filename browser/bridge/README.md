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

## Every post that gets a 🔮 is captured — open http://127.0.0.1:4747/

The bridge serves its own page: **Live** (each item as it arrives) and **Tree (graph)** (each post as a node id with its
author, group, media, links and the comment tree under it). Any post that carries a 🔮 (header chip or the action-bar
button) is sent whole as it is on screen — REC or not — and its 🔮 turns **🔮 Nexus ✓** with the node id in the tooltip.
Posts with no link of their own (ads) are kept under a text hash (`ad:…`).

## The surrogate stream (REC) — what you see, as text

Off by default. The bottom-left badge on a Facebook tab has **REC off** — click it to record THAT tab (it stays on for
that tab across reloads). While on: posts and comments that stay ≥50 % on screen for 1 s are "seen", clicks on
Like/Comment/Share/media/🔮 are actions, page changes are "nav". The badge spins while a batch is sent; a seen post's
🔮 chip turns **🔮 Nexus ✓** and its tooltip names the node it became (`post:pfbid…`).

Stored locally only (`~/.oracle-fb`, mode 700): `stream/<day>.jsonl` (the record) + `stream.db` (SQLite: events with
trigram FTS — Thai works — and the graph).

    bun seen.ts                  today          bun seen.ts --full       whole text
    bun seen.ts --follow         live, text only, pushed by the bridge (no polling)
    curl -N -H "x-fb-token: $(cat ~/.oracle-fb/token)" 127.0.0.1:4747/live     # the raw push stream (server-sent events)
    chrome-extension://hadknpihalkpmhfdppedhdoaeaddcgig/stream.html          # the same, as a page (toolbar popup → Open live stream)
    bun seen.ts "pgvector"       search         bun seen.ts --stats

### The graph

Every URL names nodes (`nodes.ts`, tested in `nodes.test.ts`):

```
 user:<name|num> ──authored──► post:<pfbid|num> ──has_media──► photo:<fbid> ──in_album──► album:<num>
                                  │   ├──in_group──► group:<id>         video:<num>
                                  │   ├──shares────► post:…             url:<external>
                                  │   └──links_to──► url:<external>
 user ──wrote──► comment:<num> ──comment_on──► post        comment ──reply_to──► comment
 me:nat ──saw / reacted / opened / opened_comments / shared / sent_to_oracle──► any node
```

    bun graph.ts --stats
    bun graph.ts post:pfbid0U569…        or a Facebook URL, or words from the text
