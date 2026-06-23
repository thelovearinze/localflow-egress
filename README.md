# Self-Healing AWS Egress Path via BGP & Containerized FRRouting

AWS Local Zones do not currently support managed NAT Gateways. As a result, workloads often depend on a single NAT instance for internet-bound traffic, creating a critical single point of failure.

This project demonstrates a routing-based approach to eliminating that dependency. Instead of relying on Lambda functions, route table updates, or instance replacement workflows, failover is handled directly by the routing protocol using AWS Transit Gateway Connect and internal BGP (iBGP).

When a NAT appliance becomes unavailable, its route is automatically withdrawn and traffic converges to the remaining healthy appliance without manual intervention.

---

## Architecture Overview

The design consists of two EC2 instances acting as NAT appliances running FRRouting (FRR) containers.

### Routing Control Plane

Each NAT instance runs a privileged Docker container hosting an FRRouting daemon.

### Overlay Network

The FRRouting containers establish iBGP sessions across a GRE tunnel backed by AWS Transit Gateway Connect attachments.

### Active/Active Load Balancing

Both NAT instances advertise a `0.0.0.0/0` default route to the Transit Gateway.

The Transit Gateway uses Equal-Cost Multi-Path (ECMP) routing to distribute outbound traffic across both nodes.

### Proactive Failover

If a NAT appliance:

- Crashes
- Freezes
- Loses upstream connectivity

The BGP hold timer expires and the Transit Gateway immediately removes the failed path.

Traffic automatically converges to the remaining healthy node within seconds.

---

## Architecture Diagram

```text
                     Internet
                         |
            +-------------------------+
            |       Transit Gateway   |
            +-------------------------+
                 /               \
                /                 \
       GRE + iBGP             GRE + iBGP
             |                     |
    +----------------+   +----------------+
    | NAT Appliance 1|   | NAT Appliance 2|
    | FRR Container  |   | FRR Container  |
    +----------------+   +----------------+
             \                 /
              \               /
               \             /
            Private Workloads
```

---

## Repository Structure

| File | Description |
|--------|-------------|
| `main.tf` | Terraform configuration containing VPC, Transit Gateway, TGW Connect attachments, EC2 instances, and networking resources |
| `.gitignore` | Excludes local state files, provider binaries, and credentials |
| `.terraform.lock.hcl` | Terraform dependency lock file |

---

## Core Technical Solutions

### 1. Decoupled Containerized Routing

To avoid dependency conflicts on minimal operating systems such as Amazon Linux 2023, the FRRouting stack runs inside a Docker container while sharing the host network namespace.

### 2. NAT Bypass Logic

Since the EC2 instances perform outbound NAT, an explicit `iptables` exemption is required.

```bash
iptables -t nat -I POSTROUTING \
-s 169.254.0.0/16 \
-j ACCEPT
```

This prevents GRE tunnel traffic from being masqueraded and ensures BGP packets reach the Transit Gateway unchanged.

### 3. Protocol Compliance

The design follows standard iBGP behavior and avoids invalid AS-PATH modifications within the same ASN.

Benefits include:

- Standards-compliant routing
- ECMP support
- Predictable failover behavior

### 4. MSS Clamping

The GRE overlay introduces additional packet overhead.

To prevent fragmentation:

```bash
iptables -t mangle -A FORWARD \
-p tcp --tcp-flags SYN,RST SYN \
-j TCPMSS --clamp-mss-to-pmtu
```

This ensures reliable TCP communication across the overlay network.

---

## Failover Testing

### Step 1: Connect to a Private Workload

Access a workload instance located behind the Transit Gateway.

### Step 2: Generate Continuous Traffic

```bash
ping 8.8.8.8
```

### Step 3: Simulate Failure

Stop FRRouting on the primary appliance:

```bash
sudo docker stop frr
```

### Step 4: Observe Recovery

The active BGP path is withdrawn and traffic automatically shifts to the surviving NAT appliance.

Expected behavior:

- A few dropped packets
- No manual intervention
- No route table updates
- Automatic convergence

---

## Key Benefits

- Active/Active NAT architecture
- BGP-driven failover
- Transit Gateway ECMP load balancing
- No route table manipulation
- No AWS Lambda dependencies
- Fast recovery during appliance failure
- Suitable for AWS Local Zones

---

## Technologies Used

- Terraform
- AWS Transit Gateway
- Transit Gateway Connect
- GRE Tunnels
- FRRouting (FRR)
- Docker
- Amazon Linux 2023
- BGP (iBGP)
- ECMP
