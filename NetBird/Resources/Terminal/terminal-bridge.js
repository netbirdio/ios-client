(function () {
  "use strict";

  var term = new Terminal({
    cursorBlink: true,
    scrollback: 5000,
    convertEol: true,
    theme: { background: "#000000" }
  });
  var fitAddon = new FitAddon.FitAddon();
  term.loadAddon(fitAddon);
  term.open(document.getElementById("terminal"));

  function post(name, payload) {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[name]) {
      window.webkit.messageHandlers[name].postMessage(payload);
    }
  }

  function base64ToBytes(base64) {
    var binary = atob(base64);
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes;
  }

  function reportSize() {
    post("terminalResize", { cols: term.cols, rows: term.rows });
  }

  term.onData(function (data) {
    post("terminalInput", { data: data });
  });

  term.onResize(function () {
    reportSize();
  });

  window.NBTerminal = {
    write: function (base64) {
      term.write(base64ToBytes(base64));
    },
    setStatus: function (text) {
      term.write("\r\n\x1b[90m" + text + "\x1b[0m\r\n");
    },
    clear: function () {
      term.clear();
    },
    focus: function () {
      term.focus();
    },
    fit: function () {
      fitAddon.fit();
    },
    getSelection: function () {
      return term.getSelection();
    }
  };

  fitAddon.fit();
  term.focus();
  post("terminalReady", { cols: term.cols, rows: term.rows });

  window.addEventListener("resize", function () {
    fitAddon.fit();
  });
})();
