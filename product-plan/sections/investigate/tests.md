# Tests: Investigate (LRE)

## Mode Activation
- Select Investigate mode: verify top bar shows "Investigate"
- Verify right panel switches to trace panel

## Trace Panel
- Send query: verify trace steps appear one by one (animated)
- Each step shows: icon (per tool type), description, duration
- Verify budget indicator updates: tool calls X/6, time X/20s
- On completion: verify all steps rendered with total time

## Tool Execution
- search: verify results description shows match count
- grep: verify pattern match results
- open: verify document section referenced
- summarize: verify summary text returned
- table_extract: verify table data extracted
- cite: verify citation object created

## Citations
- Completed investigation: verify inline citation badges in answer
- Tap citation: verify links to source document + snippet
- Multiple sources: verify all cited correctly

## Budget Exceeded
- Simulate 6+ tool calls: verify yellow banner "I stopped because I reached the search limit"
- Verify best-effort answer still displays
- Verify "Try different approach?" action button

## No Evidence
- Query with no matching documents: verify "I can't find this in your documents"
- Verify "Broaden search?" action offered
- Verify no hallucinated answer — honesty over completeness

## Security
- Verify LRE cannot access folders not in approved list
- Verify no file write operations possible
- Verify no shell/bash execution
- Verify tool parameters are strictly validated
