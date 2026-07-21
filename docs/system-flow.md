# System Flow

DrivePilot Live is a local-first observation workflow. The public repository keeps the architecture and source code while excluding private runtime data.

```text
LINE work-group notification
-> Android / MacroDroid notification forwarding
-> Local PowerShell HTTP receiver on port 8788
-> Parser and resolver scripts
-> Local generated JSON / CSV artifacts
-> Missing Coordinate Queue and MAP8 review workflow
-> Marker Builder and Marker Health
-> 24HR Statistics and Market Report Builder
-> Desktop Dashboard / Mobile Dashboard / Live Map / Market Console
```

## Flow Notes

- The receiver is local and does not operate LINE.
- Parser confidence is separate from coordinate readiness.
- The dashboard reads generated artifacts; it does not call MAP8 directly.
- MAP8 review and import are explicit local workflows with human-readable files.
- Market reports are deterministic summaries, not AI recommendations.
