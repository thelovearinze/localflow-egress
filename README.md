# Self-Healing Egress Architecture for AWS Local Zones

> A proof of concept demonstrating resilient outbound internet access for AWS Local Zones using AWS Transit Gateway Connect, GRE tunnels, containerized FRRouting, and iBGP.

 **Companion Article**

This repository accompanies the engineering case study:

**Building a Self-Healing Egress Architecture for AWS Local Zones**

https://medium.com/@thelovearinze/building-a-self-healing-egress-architecture-for-aws-local-zones-235967dadd22



# Overview

AWS Local Zones do not currently provide managed NAT Gateways. As a result, private workloads often rely on a single EC2 NAT instance for outbound internet access, introducing a critical single point of failure.

This project explores a routing-based approach to eliminating that dependency.

Instead of relying on CloudWatch alarms, Lambda functions, or route table updates after a failure occurs, failover is handled natively by the routing protocol using AWS Transit Gateway Connect and internal BGP (iBGP).

When a NAT appliance becomes unavailable, its route is automatically withdrawn and traffic converges to the remaining healthy appliance without manual intervention.


# Architecture

![Architecture Diagram](docs/architecture.png)



# Key Features

- High availability egress architecture
- AWS Transit Gateway Connect
- GRE tunnel overlay
- Containerized FRRouting (FRR)
- Internal BGP (iBGP)
- ECMP load balancing
- Automatic failover
- Infrastructure as Code using Terraform



# How It Works

Two EC2 instances act as NAT appliances inside the AWS Local Zone.

Each appliance runs FRRouting inside a Docker container and establishes an iBGP session across a GRE tunnel using AWS Transit Gateway Connect.

Both appliances advertise a default route (0.0.0.0/0).

Transit Gateway installs both routes and distributes outbound traffic using Equal Cost Multi-Path (ECMP).

If one appliance becomes unavailable:

- the BGP session drops
- the route is withdrawn
- Transit Gateway converges traffic to the remaining appliance
- outbound connectivity continues automatically

No route tables are modified.

No Lambda functions are required.


# Repository Structure

```
.
├── main.tf
├── README.md
├── .gitignore
├── .terraform.lock.hcl

```



# Technical Design Decisions

## Containerized FRRouting

Amazon Linux 2023 does not include FRRouting in the default repositories.

Instead of tightly coupling routing software to the operating system, FRRouting runs inside a privileged Docker container using the host networking stack.

This provides:

- consistent deployments
- simpler upgrades
- minimal host dependencies
- easier rollback



## NAT Bypass

Since the NAT appliances perform source NAT, GRE tunnel traffic must bypass masquerading.

```bash
iptables -t nat -I POSTROUTING \
-d 169.254.0.0/16 \
-j ACCEPT
```

Without this rule, BGP packets are translated and Transit Gateway Connect cannot establish a healthy routing session.



## MSS Clamping

GRE introduces additional packet overhead.

To prevent fragmentation, TCP MSS is adjusted automatically.

```bash
iptables -t mangle -A FORWARD \
-p tcp --tcp-flags SYN,RST SYN \
-j TCPMSS --clamp-mss-to-pmtu
```

---

# Failover Validation

Generate continuous traffic from a private workload.

```bash
ping 8.8.8.8
```

Stop FRRouting on one appliance.

```bash
docker stop frr
```

Expected result:

- BGP session drops
- Transit Gateway withdraws the failed route
- Traffic converges to the remaining appliance
- Outbound connectivity continues after a brief convergence period

---

# Technologies

- Terraform
- AWS Transit Gateway
- Transit Gateway Connect
- GRE
- FRRouting (FRR)
- Docker
- Amazon Linux 2023
- BGP (iBGP)
- ECMP

---

# Future Improvements

- Modular Terraform implementation
- Automated deployment pipeline
- Convergence benchmarking
- CloudWatch monitoring
- Additional Local Zone testing

---

# License

This project is provided as a proof of concept for educational and research purposes.

---

If you found this project useful, consider reading the companion Medium article for the complete engineering journey, design decisions, and lessons learned.

https://medium.com/@thelovearinze/building-a-self-healing-egress-architecture-for-aws-local-zones-235967dadd22
