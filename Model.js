// Model.js - Helper functions for jfarr.ip-info Omarchy plugin

.pragma library

function typeIcon(type) {
  switch (type) {
    case "ethernet":
      return "󰈀";
    case "wifi":
      return "󰤨";
    case "tailscale":
    case "vpn":
      return "󰖂";
    default:
      return "󰛳";
  }
}

function publicIcon() {
  return "󰖟";
}

function gatewayIcon() {
  return "󰌘";
}

function dnsIcon() {
  return "󰒍";
}

function formatPing(pingMs) {
  if (pingMs === undefined || pingMs === null || pingMs === "" || pingMs === "--") {
    return "--";
  }
  var n = parseFloat(pingMs);
  if (isNaN(n)) return String(pingMs);
  return n.toFixed(2) + " ms";
}

function copyIcon() {
  return "󰅍";
}

function checkIcon() {
  return "󰄬";
}

function refreshIcon() {
  return "󰑐";
}

function ipIcon() {
  return "󰩠";
}
