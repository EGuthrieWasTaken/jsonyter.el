;;; jsonyter.el --- Interactive Jupyter REPLs via the jsonyter bridge -*- lexical-binding: t; -*-

;; Author: Ethan Guthrie
;; Assisted-by: Claude:claude-fable-5
;; Assisted-by: Claude:claude-sonnet-5
;; Version: 2.7.0
;; Package-Requires: ((emacs "27.1") (org "9.4"))
;; Keywords: languages, processes, jupyter
;; URL: https://github.com/EGuthrieWasTaken/jsonyter.el

;; Copyright (C) 2026 Ethan Guthrie

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Interactive Jupyter REPL buffers for Emacs, backed by the `jsonyter'
;; Python package (https://github.com/EGuthrieWasTaken/jsonyter), which
;; exposes a Jupyter server as a line-oriented JSON protocol over
;; stdin/stdout.
;;
;; Entry points:
;;
;;   M-x jsonyter-start-python
;;   M-x jsonyter-start-julia
;;   M-x jsonyter-start-R
;;   M-x jsonyter-start-SAS
;;   M-x jsonyter-start          (prompts for a language)
;;
;; Each command starts (or pops to) a REPL buffer connected to a kernel of
;; that language on the configured Jupyter server.  The kernel spec is
;; auto-detected from the server's kernelspec list by language, or pinned
;; explicitly via `jsonyter-kernel-names'.
;;
;; Configuration (e.g. in init.el / config.el):
;;
;;   (setq jsonyter-server-url "https://jupyter.example.com:8888")
;;   ;; a (possibly gpg-encrypted) file holding the token:
;;   (setq jsonyter-server-token-file "~/.authinfo.d/jupyter-token.gpg")
;;
;; A ".gpg" token file is decrypted transparently by EasyPG (`epa-file'),
;; which is enabled by default in modern Emacs, so the token never has to
;; appear in plain text in your config.  The token is handed to the bridge
;; through the subprocess environment (`JUPYTER_TOKEN') rather than argv,
;; so it is not visible to other local users via ps — see
;; `jsonyter-token-transport'.
;;
;; In the REPL:
;;
;;   RET        send input (or continue on a new line if incomplete)
;;   M-RET      force-send input even if the kernel says it is incomplete
;;   C-j        insert a literal newline
;;   TAB        complete at point (kernel-backed)
;;   M-p / M-n  cycle input history
;;   C-c C-c    interrupt the kernel
;;   C-c C-r    restart the kernel, same id, all state lost (`jsonyter-restart',
;;              aka `jsonyter-kernel-restart')
;;   C-c C-q    shut the kernel down
;;   C-c C-d    show documentation for the thing at point
;;   C-c C-k    unstick a REPL stuck at "kernel is busy" -- Emacs-side only,
;;              the kernel itself is left running (`jsonyter-unstick')
;;   C-c M-o    clear previous output from the buffer
;;
;; Output streams in as it is produced, so a long-running cell shows its
;; `print' output live.  Rich output is rendered like a notebook where
;; Emacs allows: image/png, image/jpeg and image/svg+xml mimebundles are
;; decoded and displayed inline; text/html is rendered with shr when
;; libxml is available; ANSI escape codes are colorized.  Kernel state
;; (busy/idle/dead) is reported in the mode line from the bridge's async
;; event subscription.
;;
;; The same machinery drives four surfaces, all sharing one bridge and
;; one kernel model: the REPL, a rendered `.ipynb' (`jsonyter-notebook-open'),
;; `# %%' cells in a script (`jsonyter-script-mode'), and -- new in 2.0 --
;; `#+begin_src' blocks in an Org file whose `:session' starts with `jy:'
;; (`jsonyter-org-mode'; add `jsonyter-org-mode-maybe' to `org-mode-hook').
;; A jsonyter buffer holds a table of sessions keyed (language, name), so
;; one Org file can drive Python, R and SAS kernels at once; the public
;; accessors are `jsonyter-current-session' and `jsonyter-current-kernel-id'.
;;
;; Requires jsonyter >= 0.2 (concurrent bridge, "stream", "subscribe",
;; JUPYTER_TOKEN).  Against an older bridge the REPL still works, minus
;; live streaming and kernel-state reporting.  Document export
;; (`jsonyter-notebook-export' and friends) needs jsonyter >= 2.0.0,
;; which ships "list_export_formats"/"export_notebook"; against an
;; older bridge those commands say so plainly rather than raising a raw
;; protocol error -- see `jsonyter--list-export-formats'.  Script export
;; (`jsonyter-notebook-export-script', `jsonyter-org-export-script')
;; needs no bridge at all.
;;
;; File layout.  This file is the entry point: it carries the package
;; header (including the version) and loads the parts, so
;; (require 'jsonyter) is all a configuration needs.  Each part is a
;; library of its own, "jsonyter-NAME.el", that requires what it uses:
;;
;;   jsonyter-custom     user options (`M-x customize-group jsonyter') and faces
;;   jsonyter-core       sessions, versions, tokens, the bridge process
;;   jsonyter-complete   kernel completion, call hints, `C-c C-d' help
;;   jsonyter-repl       REPL buffers, output rendering, history, completion
;;   jsonyter-attach     attaching to a kernel that is already running
;;   jsonyter-notebook   rendered .ipynb notebooks
;;   jsonyter-latex      LaTeX preview
;;   jsonyter-transfer   file transfer, `jsonyter-remote-dired'
;;   jsonyter-sync       directory sync
;;   jsonyter-script     `# %%' script cells
;;   jsonyter-org        `jy:' source blocks in Org
;;   jsonyter-babel      the org-babel backend
;;   jsonyter-convert    .ipynb <-> .org conversion
;;   jsonyter-export     notebook and script export

;;; Code:

;; The parts, in load order; each requires the parts it depends on.
(require 'jsonyter-custom)
(require 'jsonyter-core)
(require 'jsonyter-complete)
(require 'jsonyter-repl)
(require 'jsonyter-attach)
(require 'jsonyter-notebook)
(require 'jsonyter-latex)
(require 'jsonyter-transfer)
(require 'jsonyter-sync)
(require 'jsonyter-script)
(require 'jsonyter-org)
(require 'jsonyter-babel)
(require 'jsonyter-convert)
(require 'jsonyter-export)

(provide 'jsonyter)

;;; jsonyter.el ends here
