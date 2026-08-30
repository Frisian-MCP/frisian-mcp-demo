"""
Build the NetBox demo estate.

Run inside the application container:

    /opt/netbox/venv/bin/python /opt/netbox/netbox/manage.py shell < seed/build_estate.py

Idempotent — safe to re-run.

WHAT THIS BUILDS, AND WHY IT IS SMALL
-------------------------------------
Two sites, a spine-and-leaf pair at each, an edge router, addressing, two
circuits between them, two tenants and a small virtualisation footprint.
Roughly forty objects.

It is deliberately not a large estate. The demo is about what an agent can SEE
and DO, not about how much data there is, and every object added is one more
thing to keep correct across NetBox releases. What it must do is make a
filtered query return a subset rather than everything, and make the write proof
land on something recognisable.

Everything here is fiction. The site names, addresses and serial numbers are
invented and correspond to no real network.

WHAT IT DELIBERATELY DOES NOT CREATE
------------------------------------
No Webhook, no EventRule, no ExportTemplate, no ConfigTemplate, no Script, no
DataSource. Those are the resources the scoped routes carve out, and shipping
live examples would hand anyone reaching the admin door a working outbound
request or a server-side template render. A carve-out is demonstrated by
absence from a door, which does not require an instance to exist.
"""

from django.db import transaction

from circuits.models import Circuit, CircuitTermination, CircuitType, Provider
from dcim.models import (
    Device,
    DeviceRole,
    DeviceType,
    Interface,
    Manufacturer,
    Region,
    Site,
)
from ipam.models import VLAN, IPAddress, Prefix
from tenancy.models import Tenant
from virtualization.models import Cluster, ClusterType, VirtualMachine


def slug(value):
    """NetBox slugs are lowercase, hyphenated, and unique per model."""
    out = []
    for ch in value.lower():
        if ch.isalnum():
            out.append(ch)
        elif out and out[-1] != "-":
            out.append("-")
    return "".join(out).strip("-")


def build():
    # ── Tenancy ────────────────────────────────────────────────────────────
    tenants = {}
    for name in ("Corporate", "Research"):
        tenants[name], _ = Tenant.objects.get_or_create(
            name=name, defaults={"slug": slug(name)}
        )

    # ── Geography ──────────────────────────────────────────────────────────
    region, _ = Region.objects.get_or_create(
        name="North", defaults={"slug": "north"}
    )
    sites = {}
    for name, facility in (("DC1", "Ashford"), ("DC2", "Wetherby")):
        sites[name], _ = Site.objects.get_or_create(
            name=name,
            defaults={
                "slug": slug(name),
                "region": region,
                "facility": facility,
                "tenant": tenants["Corporate"],
                "status": "active",
            },
        )

    # ── Hardware catalogue ─────────────────────────────────────────────────
    vendor, _ = Manufacturer.objects.get_or_create(
        name="Northwind Systems", defaults={"slug": "northwind-systems"}
    )
    types = {}
    for model, u in (("NW-9500 Spine", 1), ("NW-4800 Leaf", 1), ("NW-2200 Edge", 1)):
        types[model], _ = DeviceType.objects.get_or_create(
            model=model,
            manufacturer=vendor,
            defaults={"slug": slug(model), "u_height": u},
        )
    roles = {}
    for name, colour in (("Spine", "0066cc"), ("Leaf", "00cc66"), ("Edge", "cc6600")):
        roles[name], _ = DeviceRole.objects.get_or_create(
            name=name, defaults={"slug": slug(name), "color": colour}
        )

    # ── Devices ────────────────────────────────────────────────────────────
    #
    # Two leaves per site so a per-site filter returns a subset, and one edge
    # router per site to terminate the circuits below.
    devices = {}
    plan = []
    for site_name in ("DC1", "DC2"):
        plan.append((f"{site_name.lower()}-spine-01", "NW-9500 Spine", "Spine", site_name))
        plan.append((f"{site_name.lower()}-leaf-01", "NW-4800 Leaf", "Leaf", site_name))
        plan.append((f"{site_name.lower()}-leaf-02", "NW-4800 Leaf", "Leaf", site_name))
        plan.append((f"{site_name.lower()}-edge-01", "NW-2200 Edge", "Edge", site_name))

    for name, model, role, site_name in plan:
        devices[name], _ = Device.objects.get_or_create(
            name=name,
            defaults={
                "device_type": types[model],
                "role": roles[role],
                "site": sites[site_name],
                "tenant": tenants["Corporate"],
                "status": "active",
                "serial": f"NW{abs(hash(name)) % 10**8:08d}",
            },
        )

    # ── Interfaces ─────────────────────────────────────────────────────────
    #
    # Four uplinks per device. Enough for an agent to page through and for a
    # filtered query to mean something; not so many that the estate becomes
    # about interface count.
    for dev in devices.values():
        for n in range(1, 5):
            Interface.objects.get_or_create(
                device=dev, name=f"Ethernet1/{n}", defaults={"type": "25gbase-x-sfp28"}
            )

    # ── Addressing ─────────────────────────────────────────────────────────
    prefixes = {}
    for cidr, site_name, descr in (
        ("10.1.0.0/16", "DC1", "DC1 aggregate"),
        ("10.2.0.0/16", "DC2", "DC2 aggregate"),
        ("10.1.10.0/24", "DC1", "DC1 management"),
        ("10.2.10.0/24", "DC2", "DC2 management"),
    ):
        # `scope`, not `site`. NetBox 4.2 replaced Prefix.site with a generic
        # scope (Region / SiteGroup / Site / Location), and `site` survives only
        # as a REVERSE accessor — assigning to it raises
        # "Direct assignment to the reverse side of a related set is
        # prohibited", which names neither Prefix nor the version that changed.
        prefixes[cidr], _ = Prefix.objects.get_or_create(
            prefix=cidr,
            defaults={
                "scope": sites[site_name],
                "tenant": tenants["Corporate"],
                "status": "active",
                "description": descr,
            },
        )

    for vid, name, site_name in ((10, "mgmt", "DC1"), (20, "storage", "DC1"), (10, "mgmt", "DC2")):
        VLAN.objects.get_or_create(
            vid=vid, name=name, site=sites[site_name], defaults={"status": "active"}
        )

    # One management address per device, on its first interface.
    for idx, (name, dev) in enumerate(sorted(devices.items()), start=11):
        octet = "1" if name.startswith("dc1") else "2"
        iface = Interface.objects.filter(device=dev, name="Ethernet1/1").first()
        if iface is None:
            continue
        addr = f"10.{octet}.10.{idx}/24"
        ip, _ = IPAddress.objects.get_or_create(
            address=addr,
            defaults={"status": "active", "tenant": tenants["Corporate"]},
        )
        ip.assigned_object = iface
        ip.save()

    # ── Circuits ───────────────────────────────────────────────────────────
    provider, _ = Provider.objects.get_or_create(
        name="Cascade Transit", defaults={"slug": "cascade-transit"}
    )
    ctype, _ = CircuitType.objects.get_or_create(
        name="Dark Fibre", defaults={"slug": "dark-fibre"}
    )
    for cid, a_site, z_site in (("CT-1001", "DC1", "DC2"), ("CT-1002", "DC1", "DC2")):
        circuit, _ = Circuit.objects.get_or_create(
            cid=cid,
            provider=provider,
            defaults={
                "type": ctype,
                "status": "active",
                "tenant": tenants["Corporate"],
            },
        )
        for term_side, site_name in (("A", a_site), ("Z", z_site)):
            CircuitTermination.objects.get_or_create(
                circuit=circuit,
                term_side=term_side,
                defaults={"termination": sites[site_name]},
            )

    # ── Virtualisation ─────────────────────────────────────────────────────
    cluster_type, _ = ClusterType.objects.get_or_create(
        name="Hypervisor", defaults={"slug": "hypervisor"}
    )
    cluster, _ = Cluster.objects.get_or_create(
        name="DC1 Compute",
        defaults={"type": cluster_type, "scope": sites["DC1"], "status": "active"},
    )
    for vm_name, tenant in (("app-01", "Corporate"), ("lab-01", "Research")):
        VirtualMachine.objects.get_or_create(
            name=vm_name,
            defaults={
                "cluster": cluster,
                "tenant": tenants[tenant],
                "status": "active",
                "vcpus": 4,
                "memory": 8192,
            },
        )

    print(f"  tenants        {Tenant.objects.count()}")
    print(f"  regions        {Region.objects.count()}")
    print(f"  sites          {Site.objects.count()}")
    print(f"  device types   {DeviceType.objects.count()}")
    print(f"  device roles   {DeviceRole.objects.count()}")
    print(f"  devices        {Device.objects.count()}")
    print(f"  interfaces     {Interface.objects.count()}")
    print(f"  prefixes       {Prefix.objects.count()}")
    print(f"  vlans          {VLAN.objects.count()}")
    print(f"  ip addresses   {IPAddress.objects.count()}")
    print(f"  circuits       {Circuit.objects.count()}")
    print(f"  terminations   {CircuitTermination.objects.count()}")
    print(f"  clusters       {Cluster.objects.count()}")
    print(f"  virtual machines {VirtualMachine.objects.count()}")


def truncate_history():
    """Empty the change log that BUILDING the estate produced.

    Every save above writes an ObjectChange. That is a build-time audit trail,
    not part of the demo — and it names demo-builder, which is supposed to
    leave no trace. Changes a user makes while exploring are logged normally.

    The same reasoning cost the Paperless host a shipped estate full of failed
    task rows: build residue is easy to leave behind because nothing looks at
    it. See netbox/db/assert-identities.sh, which asserts this is empty.
    """
    from core.models import ObjectChange

    deleted, _ = ObjectChange.objects.all().delete()
    print(f"  change log     {deleted} build-time record(s) truncated")


print("Building the frisian-mcp NetBox demo estate")
with transaction.atomic():
    build()
truncate_history()
print("Done.")
