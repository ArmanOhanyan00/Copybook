#!/usr/bin/env node
// Runs Copybook's installer (install.sh, shipped in this package).
//
//   npm install -g ArmanOhanyan00/Copybook    installs the app (this runs automatically as part of the install)
//   copybook-mac                             installs or updates the app again
//   copybook-mac --uninstall                 removes the app
//   npx ArmanOhanyan00/Copybook               installs the app without keeping the command
//
// The options are the ones install.sh has; run copybook-mac --help to see them.
"use strict";
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

let args = process.argv.slice(2);
const automatic = args[0] === "--postinstall";
if (automatic) args = args.slice(1);
if (args[0] === "install") args = args.slice(1);

if (process.platform !== "darwin") {
  if (automatic) process.exit(0);
  console.error("Copybook is a macOS app, and this isn't a Mac.");
  process.exit(1);
}
if (automatic) {
  // Not when working inside a copy of the source code, and not when asked to skip.
  const root = path.join(__dirname, "..");
  if (process.env.COPYBOOK_SKIP_POSTINSTALL || fs.existsSync(path.join(root, "Package.swift"))) process.exit(0);
}

// npm hides the output of install scripts. Talk to the terminal directly so the questions and
// progress are visible; with no terminal (a script, CI) the installer just uses its defaults.
let stdio = "inherit";
if (automatic) {
  try {
    const tty = fs.openSync("/dev/tty", "r+");
    stdio = [tty, tty, tty];
  } catch (_) { /* no terminal */ }
}

const script = path.join(__dirname, "..", "install.sh");
const run = spawnSync("/bin/bash", [script, ...args], { stdio });
process.exit(run.status === null ? 1 : run.status);
