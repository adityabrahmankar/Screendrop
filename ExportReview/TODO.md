# Export implementation goal and task status

Preserve existing export output and timing while reducing avoidable serialization
and repeated work, with bounded application-held pending frame resources.

- [x] Resolve actual GitHub state: staged candidate versus production source.
- [x] Recover exact source from successful native validation run 34152606749.
- [x] Check relevant Apple Metal/Core Video lifetime and writer documentation.
- [x] Integrate the candidate as ordinary Swift source, not encoded CI-only patches.
- [x] Audit buffer lifetimes, cancellation/finalization, timeline and cache keys.
- [x] Re-run portable Swift tests: 555,684 mapping comparisons plus cancellation/wakeup checks.
- [x] Recheck 2,352 stored pixel/PTS comparisons and classify benchmark limitations.
- [x] Add reproducible build/test commands and optimized long-export test entry point.
      The new native scripts have syntax/helper checks, not a fresh macOS execution.
- [x] Carry forward main's independent shadow fix with exact Git blob-hash verification.
- [x] Verify patch application on the exact pass1 tree and preserve existing local edits.
- [x] Package source, patch, evidence, safe worktree application helper and change report.
- [ ] Publish remote branch/PR. Blocked: read-only GitHub connector and no container GitHub network access.
- [ ] Run the final combined source and new long fixture on native macOS.
- [ ] Measure sustained throughput, memory plateau and A/V sync on physical Apple Silicon.
- [ ] Complete full-disk/encoder-failure/finalization-cancellation and macOS 26.0 release gates.

The unchecked tasks remain release gates, not silently assumed successes. Historical
native results prove the tested export candidate's covered cases, not every real
recording, all codecs, an hour-long physical export or the final combined package.
