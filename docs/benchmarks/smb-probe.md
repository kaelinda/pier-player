# SMB Probe

`SMBProbe` verifies directory access and measures aligned sequential reads through the production page cache and persistent libsmb2 file handle.

Build and run it in Release mode:

```bash
export PIER_SMB_HOST=nas.local
export PIER_SMB_SHARE=Media
export PIER_SMB_USER=viewer
export PIER_SMB_DOMAIN=WORKGROUP          # optional
export PIER_SMB_ENCRYPTION=true           # optional, default false
export PIER_SMB_FILE=/Movies/sample.mkv   # optional
export PIER_SMB_PROBE_BYTES=268435456      # optional, default 256 MiB
swift run -c release SMBProbe
```

The command reads the password interactively with terminal echo disabled. Do not put passwords in environment variables, shell history, benchmark reports, or command arguments.

Without `PIER_SMB_FILE`, the probe only connects and reports `root_entries`. With a file, it also reports `bytes`, `elapsed_seconds`, `throughput_mib_s`, `cache_hits`, `cache_misses`, `upstream_reads`, and `upstream_bytes`. It never prints the host, share, username, password, or file path.

Record results alongside the reference environment details required by the architecture spec: Mac model, macOS version, NAS model and storage, SMB dialect/signing/encryption, link type, and network equipment. Run at least three times after NAS caches and disks have reached a representative state.
