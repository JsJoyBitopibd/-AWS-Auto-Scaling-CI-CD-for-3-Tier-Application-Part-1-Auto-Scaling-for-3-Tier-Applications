# How the Servers Talk to Each Other

> Status: **in progress** — written alongside the build.

A hop-by-hop explanation of every network conversation in this system — browser ↔ load balancer, load balancer ↔ backend servers (traffic and health checks), backend ↔ database, servers ↔ AWS metadata service, and (in Part 2) the pipeline ↔ the fleet — in plain words, with the actual commands and ports used at each hop.
