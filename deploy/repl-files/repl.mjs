import { WebR, Console } from 'https://webr.r-wasm.org/latest/webr.mjs';

(async () => {
  const webR = new WebR();
  await webR.init();
  
  await webR.evalR(`
    options(
      repos = c("https://my-repo.com", "https://repo.r-wasm.org"),
      webr_pkg_repos = c("https://my-repo.com", "https://repo.r-wasm.org")
    )
  `);
  
  const consoleElement = document.getElementById('root');
  const webRConsole = new Console({
    stdout: line => {
      const pre = document.createElement('pre');
      pre.textContent = line;
      consoleElement.appendChild(pre);
    },
    stderr: line => {
      const pre = document.createElement('pre');
      pre.style.color = '#ff5555';
      pre.textContent = line;
      consoleElement.appendChild(pre);
    },
    prompt: p => {
      const pre = document.createElement('pre');
      pre.textContent = p;
      pre.style.fontWeight = 'bold';
      consoleElement.appendChild(pre);
    }
  }, { webR });
  
  webRConsole.run();
  webRConsole.stdin('cat("\\nCustom repositories configured:", getOption("repos"), "\\n\\n")');
})();
