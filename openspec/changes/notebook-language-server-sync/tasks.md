# Tasks

- [x] 1.1 `jsonyter--nb-silent-replace`: run the change hooks around a silent replacement, containing hook errors
- [x] 1.2 Use it for a cell's output rewrite and for removing a cell's output with the cell
- [x] 1.3 Test: a tracker that mirrors the buffer from `after-change-functions` stays equal to it across writing, replacing, clearing and excising; the before hook sees the old text
- [x] 1.4 Test: no modified flag, no undo entries; a failing hook does not stop output
- [x] 1.5 `jsonyter--nb-indent-line-in-cell` advice, installed and removed with the mode
- [x] 1.6 Tests: an earlier cell's open bracket does not indent the next cell; brackets within a cell still do; narrowing does not outlive the call; the advice leaves with the mode
- [x] 1.7 README language-server section
- [x] 1.8 `;; Version:` bumped once for the whole run
