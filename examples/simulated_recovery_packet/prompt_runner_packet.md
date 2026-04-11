---
name: "simulated-recovery-packet"
profile: "simulated-default"
provider: "simulated"
model: "simulated-demo"
permission_mode: "bypass"
cli_confirmation: "off"
retry_attempts: 2
auto_repair: true
repos:
  app:
    path: "./workspace"
    default: true
phases:
  "1": "Automatic Recovery"
  "2": "Session Recovery"
---
# Simulated Recovery Packet

Zero-dependency recovery demo for Prompt Runner 0.7.0.
