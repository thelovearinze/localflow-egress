# Self-Healing AWS Egress Path via BGP & Containerized FRRouting

This repository contains a highly available, self-healing egress routing architecture designed for AWS environments with strict zonal constraints (such as AWS Local Zones) where managed NAT Gateways are unavailable. 

Instead of relying on fragile, reactive automation scripts (like Lambda or CloudWatch route updates) that introduce minutes of downtime during an outage, this architecture pushes failover detection down to the network protocol layer using **internal BGP (iBGP)** and **AWS Transit Gateway Connect**.

## Architecture Overview

The design leverages two standard EC2 instances configured as NAT appliances running side-by-side within a single zone. 

1. **Routing Control Plane:** Each NAT instance runs a privileged Docker container hosting an **FRRouting (FRR)** daemon.
2. **Overlay Network:** The FRR container establishes an iBGP session over a GRE tunnel back to the AWS Transit Gateway (TGW) Connect endpoints.
3. **Active/Active Load Balancing:** Both instances actively advertise a `0.0.0.0/0` default route to the TGW. The TGW uses **Equal-Cost Multi-Path (ECMP)** routing to balance outbound traffic evenly across both nodes.
4. **Proactive Failover:** If an instance crashes, freezes, or loses upstream connectivity, the BGP hold timer expires. The TGW instantly drops the path and seamlessly routes 100% of egress traffic to the remaining healthy instance within seconds.

## Repository Structure

* `main.tf`: The monolithic Terraform configuration containing the VPC layout, subnets, Transit Gateway, TGW Connect attachments, and EC2 computing resources.
* `.gitignore`: Configured to keep local state files, provider binaries, and credentials out of version control.
* `.terraform.lock.hcl`: Dependency lock file ensuring predictable deployment execution.

## Core Technical Solutions & Fixes Implemented

### 1. Decoupled Containerized Routing
To avoid dependency collision and versioning issues within minimal host distributions like Amazon Linux 2023 (AL2023), the FRRouting engine is deployed inside a container sharing the host network stack.

### 2. NAT Bypass Logic
Because the instances perform outbound translation, a specific `iptables` rule is implemented at the top of the `POSTROUTING` chain to explicitly exempt GRE tunnel traffic (`169.254.0.0/16`) from undergoing masquerade processing. This prevents the Transit Gateway from silently dropping modified BGP packets.

### 3. Protocol Compliance
The setup relies on clean routing logic that honors strict iBGP rules. It avoids invalid AS-Path modifications within a single Autonomous System Number (ASN), allowing native ECMP path selection across the active nodes.

### 4. MSS Clamping
To prevent fragmentation and packet drops across the GRE overlay network (which introduces a 24-byte header overhead), TCP Maximum Segment Size (MSS) clamping is enforced on the tunnel interface.

## How to Test Failover Recovery

1. Access a private workload instance located behind the Transit Gateway.
2. Initiate a continuous egress traffic validation test:
   `ping 8.8.8.8`
3. Simulate a sudden infrastructure drop by stopping the routing control plane on the primary NAT appliance:
   `sudo docker stop frr`
4. Observe the continuous stream. The routing path shifts to the backup instance within a few lost packets, requiring zero API coordination or manual route table alterations.