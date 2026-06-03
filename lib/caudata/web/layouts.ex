defmodule Caudata.Web.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()}/>
        <title>Caudata Logs Streamer</title>
        <style>
          body {
            margin: 0;
            background: #1a1a2e;
            color: #e0e0e0;
            font-family: monospace;
          }
          /* Prevent browser focus outlines, tap highlights, and text selection highlights */
          #phoenix-ex-ratatui, .pxr-row, .pxr-cell {
            outline: none !important;
            box-shadow: none !important;
            user-select: none !important;
            -webkit-user-select: none !important;
            -moz-user-select: none !important;
            -ms-user-select: none !important;
            -webkit-tap-highlight-color: transparent !important;
          }
        </style>
        <script src="https://cdn.jsdelivr.net/npm/phoenix@1.8.7/priv/static/phoenix.min.js"></script>
        <script src="https://cdn.jsdelivr.net/npm/phoenix_live_view@1.1.31/priv/static/phoenix_live_view.min.js"></script>
        <script>
          // Color tables
          const NAMED_COLORS = {
            black: "#000000",
            red: "#cc0000",
            green: "#4e9a06",
            yellow: "#c4a000",
            blue: "#3465a4",
            magenta: "#75507b",
            cyan: "#06989a",
            gray: "#d3d7cf",
            dark_gray: "#555753",
            light_red: "#ef2929",
            light_green: "#8ae234",
            light_yellow: "#fce94f",
            light_blue: "#729fcf",
            light_magenta: "#ad7fa8",
            light_cyan: "#34e2e2",
            white: "#eeeeec",
          };

          const DEFAULT_FG = NAMED_COLORS.white;
          const DEFAULT_BG = NAMED_COLORS.black;

          function colorToCss(color) {
            if (color == null || color === "reset") return null;
            if (typeof color === "string") return NAMED_COLORS[color] ?? null;
            if (Array.isArray(color)) {
              if (color[0] === "rgb") return `rgb(${color[1]}, ${color[2]}, ${color[3]})`;
              if (color[0] === "indexed") return indexedColor(color[1]);
            }
            return null;
          }

          function indexedColor(n) {
            if (n < 16) {
              const order = [
                "black", "red", "green", "yellow", "blue", "magenta", "cyan", "gray",
                "dark_gray", "light_red", "light_green", "light_yellow",
                "light_blue", "light_magenta", "light_cyan", "white",
              ];
              return NAMED_COLORS[order[n]];
            }
            if (n < 232) {
              const i = n - 16;
              const r = Math.floor(i / 36);
              const g = Math.floor((i % 36) / 6);
              const b = i % 6;
              const step = (v) => (v === 0 ? 0 : 55 + v * 40);
              return `rgb(${step(r)}, ${step(g)}, ${step(b)})`;
            }
            const v = (n - 232) * 10 + 8;
            return `rgb(${v}, ${v}, ${v})`;
          }

          const STYLE_TAG_ID = "phx-ex-ratatui-cell-style";

          function ensureBaseStyle() {
            if (document.getElementById(STYLE_TAG_ID)) return;
            const tag = document.createElement("style");
            tag.id = STYLE_TAG_ID;
            tag.textContent =
              ".pxr-row{display:flex;line-height:1}" +
              ".pxr-cell{display:inline-block;width:var(--pxr-cw);height:var(--pxr-ch);text-align:center}";
            document.head.appendChild(tag);
          }

          function buildStyle(fg, bg, modifiers) {
            let fgCss = colorToCss(fg) || "";
            let bgCss = colorToCss(bg) || "";

            let bold = false, italic = false, dim = false;
            let under = false, cross = false, reversed = false;
            for (let i = 0; i < modifiers.length; i++) {
              const m = modifiers[i];
              if (m === "bold") bold = true;
              else if (m === "italic") italic = true;
              else if (m === "dim") dim = true;
              else if (m === "underlined") under = true;
              else if (m === "crossed_out") cross = true;
              else if (m === "reversed") reversed = true;
            }

            if (reversed) {
              const newFg = bgCss || DEFAULT_BG;
              const newBg = fgCss || DEFAULT_FG;
              fgCss = newFg;
              bgCss = newBg;
            }

            let css = "";
            if (fgCss) css = "color:" + fgCss;
            if (bgCss) css += (css ? ";" : "") + "background-color:" + bgCss;
            if (bold) css += (css ? ";" : "") + "font-weight:bold";
            if (italic) css += (css ? ";" : "") + "font-style:italic";
            if (dim) css += (css ? ";" : "") + "opacity:0.6";
            if (under && cross) css += (css ? ";" : "") + "text-decoration:underline line-through";
            else if (under) css += (css ? ";" : "") + "text-decoration:underline";
            else if (cross) css += (css ? ";" : "") + "text-decoration:line-through";

            return { fg: fgCss, bg: bgCss, css };
          }

          const KEY_MAP = {
            ArrowUp: "up",
            ArrowDown: "down",
            ArrowLeft: "left",
            ArrowRight: "right",
            Enter: "enter",
            Escape: "esc",
            Backspace: "backspace",
            Tab: "tab",
            Delete: "delete",
            Insert: "insert",
            Home: "home",
            End: "end",
            PageUp: "page_up",
            PageDown: "page_down",
          };

          function keyToCode(event) {
            if (KEY_MAP[event.key]) return KEY_MAP[event.key];
            if (/^F\d+$/.test(event.key)) return event.key.toLowerCase();
            return event.key;
          }

          function modifiersFor(event) {
            const mods = [];
            if (event.ctrlKey) mods.push("ctrl");
            if (event.shiftKey) mods.push("shift");
            if (event.altKey) mods.push("alt");
            if (event.metaKey) mods.push("meta");
            return mods;
          }

          window.PhoenixExRatatuiHook = {
            mounted() {
              this.cells = [];
              this.charWidth = 0;
              this.charHeight = 0;

              if (this.el.tabIndex < 0) this.el.tabIndex = 0;

              if (!this.el.style.fontFamily) {
                this.el.style.fontFamily = "ui-monospace, monospace";
              }
              if (!this.el.style.whiteSpace) this.el.style.whiteSpace = "pre";
              if (!this.el.style.lineHeight) this.el.style.lineHeight = "1";
              if (!this.el.style.overflow) this.el.style.overflow = "hidden";

              ensureBaseStyle();

              if (this.el.dataset.phxExRatatuiAutofocus === "true") {
                this.el.focus({ preventScroll: true });
              }

              this.measureChar();
              this.reportSize();

              this.handleEvent("phx_ex_ratatui:render", (payload) => this.applyDiff(payload));

              this.resizeObserver = new ResizeObserver(() => this.reportSize());
              this.resizeObserver.observe(this.el);

              this.keydownListener = (event) => this.onKeydown(event);
              this.el.addEventListener("keydown", this.keydownListener);
            },

            destroyed() {
              if (this.resizeObserver) this.resizeObserver.disconnect();
              if (this.keydownListener) this.el.removeEventListener("keydown", this.keydownListener);
            },

            measureChar() {
              const probe = document.createElement("span");
              probe.style.cssText = "visibility:hidden;position:absolute;font:inherit;white-space:pre";
              probe.textContent = "M";
              this.el.appendChild(probe);
              const rect = probe.getBoundingClientRect();
              this.charWidth = rect.width || 8;
              this.charHeight = rect.height || 16;
              probe.remove();

              this.el.style.setProperty("--pxr-cw", this.charWidth + "px");
              this.el.style.setProperty("--pxr-ch", this.charHeight + "px");
            },

            reportSize() {
              if (!this.charWidth || !this.charHeight) return;
              const rect = this.el.getBoundingClientRect();
              let cols = Math.floor(rect.width / this.charWidth);
              let rows = Math.floor(rect.height / this.charHeight);

              if (cols < 1 || rows < 1) {
                cols = 80;
                rows = 24;
              }

              this.pushEventTo(this.el, "phx_ex_ratatui:resize", { cols, rows });
            },

            applyDiff({ width, height, ops }) {
              const dimsChanged =
                this.cells.length !== height ||
                (this.cells[0] && this.cells[0].length !== width);

              if (dimsChanged) this.buildGrid(width, height);

              for (let i = 0; i < ops.length; i++) {
                const [row, col, sym, fg, bg, mods, skip] = ops[i];
                this.setCell(row, col, sym, fg, bg, mods, skip);
              }
            },

            buildGrid(width, height) {
              this.el.replaceChildren();
              this.cells = [];

              for (let r = 0; r < height; r++) {
                const row = document.createElement("div");
                row.className = "pxr-row";
                const rowCells = new Array(width);

                for (let c = 0; c < width; c++) {
                  const cell = document.createElement("span");
                  cell.className = "pxr-cell";
                  cell.textContent = " ";
                  cell._sym = " ";
                  cell._fg = "";
                  cell._bg = "";
                  cell._mods = "";
                  row.appendChild(cell);
                  rowCells[c] = cell;
                }

                this.cells.push(rowCells);
                this.el.appendChild(row);
              }
            },

            setCell(row, col, sym, fg, bg, modifiers, skip) {
              const rowCells = this.cells[row];
              if (!rowCells) return;
              const cell = rowCells[col];
              if (!cell) return;
              if (skip) return;

              const modsKey = modifiers.length ? modifiers.join(",") : "";
              const built = buildStyle(fg, bg, modifiers);

              if (
                cell._sym === sym &&
                cell._fg === built.fg &&
                cell._bg === built.bg &&
                cell._mods === modsKey
              ) {
                return;
              }

              cell._sym = sym;
              cell._fg = built.fg;
              cell._bg = built.bg;
              cell._mods = modsKey;

              if (cell.textContent !== sym) cell.textContent = sym;
              cell.style.cssText = built.css;
            },

            onKeydown(event) {
              event.preventDefault();
              this.pushEventTo(this.el, "phx_ex_ratatui:input", {
                kind: "key",
                code: keyToCode(event),
                modifiers: modifiersFor(event),
                press_kind: "press",
              });
            },
          };

          window.addEventListener("DOMContentLoaded", () => {
            let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

            let Hooks = { PhoenixExRatatuiHook: window.PhoenixExRatatuiHook }

            let liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken},
              hooks: Hooks
            })
            liveSocket.connect()
            window.liveSocket = liveSocket
          })
        </script>
      </head>
      <body>
        <%= @inner_content %>
      </body>
    </html>
    """
  end
end
