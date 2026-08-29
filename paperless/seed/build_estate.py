"""
Apply the demo estate's metadata to the consumed documents.

Run inside the application container, AFTER every corpus file has been
consumed:

    python3 manage.py shell < seed/build_estate.py

Idempotent — safe to re-run against the same instance.

WHY METADATA IS APPLIED HERE AND NOT LEFT TO PAPERLESS
------------------------------------------------------
Paperless can guess a document's correspondent, type and tags from its content.
That is a nice feature of Paperless and it is not what this demo is
demonstrating — and a corpus that is filed correctly only when the classifier
guesses right is not reproducible. Two builds of the same image would ship
different estates, and a wrong guess would look like a frisian-mcp bug.

So the corpus generator emits a manifest saying what each document IS, and this
script applies it. Nothing here is inferred.

WHAT IT DELIBERATELY DOES NOT CREATE
------------------------------------
No ShareLink, no MailAccount, no Workflow with a webhook action. Those are the
resources the scoped routes carve out, and a demo estate that ships live
examples of them hands anyone who reaches the admin door a working outbound
request and a public document URL. The carve-out is demonstrated by the
resources being ABSENT from a door, which does not require an instance to
exist.

One Workflow IS created, with a purely local action (apply a tag). It exists so
the `workflow` dispatcher has something to list on the read-only door — the
group is browsable there and unwritable on both scoped doors, and an empty list
demonstrates neither.
"""

import json
import sys
from datetime import date
from pathlib import Path

from django.contrib.auth import get_user_model
from django.db import transaction

from documents.models import (
    Correspondent,
    CustomField,
    CustomFieldInstance,
    Document,
    DocumentType,
    SavedView,
    SavedViewFilterRule,
    StoragePath,
    Tag,
    Workflow,
    WorkflowAction,
    WorkflowTrigger,
)

MANIFEST = Path("/usr/src/paperless/demo-seed/manifest.json")


def load_manifest():
    if not MANIFEST.exists():
        print(f"REFUSING TO BUILD: {MANIFEST} not found.")
        print("  The corpus manifest is produced by seed/corpus.py and copied")
        print("  into the container by seed/seed.sh. Without it this script")
        print("  would silently produce an estate with no metadata.")
        sys.exit(1)
    return json.loads(MANIFEST.read_text(encoding="utf-8"))


def build_taxonomy(manifest):
    """Create correspondents, types, tags, storage paths and custom fields."""
    correspondents = {}
    for name in manifest["correspondents"]:
        obj, _ = Correspondent.objects.get_or_create(name=name)
        correspondents[name] = obj

    types = {}
    for name in manifest["document_types"]:
        obj, _ = DocumentType.objects.get_or_create(name=name)
        types[name] = obj

    tags = {}
    for entry in manifest["tags"]:
        obj, created = Tag.objects.get_or_create(
            name=entry["name"], defaults={"color": entry["colour"]}
        )
        if not created and obj.color != entry["colour"]:
            obj.color = entry["colour"]
            obj.save()
        tags[entry["name"]] = obj

    paths = {}
    for entry in manifest["storage_paths"]:
        obj, _ = StoragePath.objects.get_or_create(
            name=entry["name"], defaults={"path": entry["path"]}
        )
        paths[entry["name"]] = obj

    fields = {}
    for entry in manifest["custom_fields"]:
        obj, _ = CustomField.objects.get_or_create(
            name=entry["name"], defaults={"data_type": entry["data_type"]}
        )
        fields[entry["name"]] = obj

    print(
        f"  taxonomy: {len(correspondents)} correspondents, {len(types)} types, "
        f"{len(tags)} tags, {len(paths)} storage paths, {len(fields)} custom fields"
    )
    return correspondents, types, tags, paths, fields


def set_custom_field(document, field, raw):
    """Write one custom field value into the column its data type uses."""
    attr = CustomFieldInstance.get_value_field_name(field.data_type)
    value = raw
    if field.data_type == CustomField.FieldDataType.DATE:
        value = date.fromisoformat(raw)
    instance, _ = CustomFieldInstance.objects.get_or_create(
        document=document, field=field
    )
    setattr(instance, attr, value)
    instance.save()


def apply_documents(manifest, correspondents, types, tags, fields):
    """Match each consumed document to its manifest entry and file it."""
    applied = 0
    missing = []

    for entry in manifest["documents"]:
        # original_filename is what the consumer records, and it is the only
        # stable link back to the corpus: the title gets rewritten by this very
        # script, and the checksum depends on the PDF bytes rather than on
        # anything the manifest knows.
        document = Document.objects.filter(
            original_filename=entry["filename"]
        ).first()
        if document is None:
            missing.append(entry["filename"])
            continue

        document.title = entry["title"]
        document.correspondent = correspondents[entry["correspondent"]]
        document.document_type = types[entry["document_type"]]
        document.created = date.fromisoformat(entry["created"])
        document.save()

        document.tags.set([tags[name] for name in entry["tags"]])

        for field_name, raw in entry["custom_fields"].items():
            set_custom_field(document, fields[field_name], raw)

        applied += 1

    if missing:
        # HARD FAILURE, deliberately.
        #
        # A partially consumed corpus is the failure mode this whole pipeline
        # is most likely to hit — the consumer is asynchronous, and "the seed
        # finished before consumption did" produces an estate that is short a
        # few documents and otherwise looks completely fine. Shipping that
        # silently is how a demo ends up with an unexplained gap in it.
        print(f"REFUSING TO BUILD: {len(missing)} corpus file(s) were never consumed:")
        for name in sorted(missing):
            print(f"    {name}")
        print("  Wait for consumption to finish and re-run, or check the")
        print("  consumer log for a document Paperless rejected.")
        sys.exit(1)

    print(f"  documents: {applied} filed")
    return applied


def build_saved_views(tags, types):
    """Two saved views per demo identity, so `monitoring` lists something real.

    ⚠️ SAVED VIEWS ARE OWNER-SCOPED, AND AN UNOWNED ONE IS INVISIBLE TO EVERYONE.

    Measured, not assumed. `SavedViewViewSet.get_queryset` is

        SavedView.objects.filter(owner=user)

    with no superuser branch — so a SavedView with `owner=NULL` is returned to
    nobody, demo-admin included. The first cut of this script created two
    unowned views; they were in the database, they were in the dump, and the
    `monitoring` dispatcher reported `count: 0` through every door. Nothing
    anywhere said why.

    So each identity gets its own copy. That is also the honest model: in
    Paperless a saved view IS per-user, and giving every demo identity a
    dashboard is what a real instance looks like.
    """
    User = get_user_model()
    made = 0

    for username in ("demo-readonly", "demo-editor", "demo-admin"):
        owner = User.objects.filter(username=username).first()
        if owner is None:
            # Not fatal: this script is re-runnable against an instance that
            # has not been provisioned yet, and a missing identity there is a
            # sequencing problem for seed.sh to report rather than a reason to
            # abandon the rest of the estate.
            print(f"  ! saved views: no such user {username}, skipped")
            continue

        unpaid, _ = SavedView.objects.get_or_create(
            name="Unpaid invoices",
            owner=owner,
            defaults={
                "show_on_dashboard": True,
                "show_in_sidebar": True,
                "sort_field": "created",
                "sort_reverse": True,
            },
        )
        SavedViewFilterRule.objects.filter(saved_view=unpaid).delete()
        # 6 = "has tag", 4 = "document type is". Rule types are integers on the
        # model; the names are in SavedViewFilterRule.RULE_TYPES.
        SavedViewFilterRule.objects.create(
            saved_view=unpaid, rule_type=6, value=str(tags["unpaid"].pk)
        )
        SavedViewFilterRule.objects.create(
            saved_view=unpaid, rule_type=4, value=str(types["Invoice"].pk)
        )

        tax, _ = SavedView.objects.get_or_create(
            name="Tax year 2026",
            owner=owner,
            defaults={
                "show_on_dashboard": True,
                "show_in_sidebar": True,
                "sort_field": "created",
                "sort_reverse": True,
            },
        )
        SavedViewFilterRule.objects.filter(saved_view=tax).delete()
        SavedViewFilterRule.objects.create(
            saved_view=tax, rule_type=6, value=str(tags["tax-2026"].pk)
        )
        made += 2

    print(f"  saved views: {made} (2 per demo identity)")


def build_workflow(tags):
    """One workflow with a LOCAL action only. See the module docstring."""
    workflow, _ = Workflow.objects.get_or_create(
        name="Flag urgent on consumption",
        defaults={"order": 0, "enabled": False},
    )
    # Disabled on purpose. It exists to be LISTED, not to fire: a workflow that
    # retags every document a demo user adds makes the demo's behaviour depend
    # on invisible state.
    workflow.enabled = False
    workflow.save()

    # 1 = consumption. WorkflowTrigger.WorkflowTriggerType.CONSUMPTION.
    trigger, _ = WorkflowTrigger.objects.get_or_create(
        type=WorkflowTrigger.WorkflowTriggerType.CONSUMPTION,
        defaults={"filter_filename": "*urgent*"},
    )
    action, _ = WorkflowAction.objects.get_or_create(
        type=WorkflowAction.WorkflowActionType.ASSIGNMENT,
    )
    action.assign_tags.set([tags["urgent"]])
    action.save()

    workflow.triggers.set([trigger])
    workflow.actions.set([action])
    print("  workflows: 1 (disabled, local action only)")


def truncate_build_tasks():
    """Empty the task queue that BUILDING the estate produced.

    Consuming the corpus creates a `PaperlessTask` row per file, and those rows
    are a build-time trail exactly like the audit log: they describe how the
    estate was made, not what it contains. Left in place they ship inside
    demo.sql.gz, and `monitoring/tasks/list` — a documented part of the demo —
    hands an agent a pile of build artefacts as though they were the estate.

    This shipped once. The published v0.1.0-pre estate carries 13 FAILURE and
    10 PENDING rows, because the seed used to queue every file twice (see the
    note against `--oneshot` in seed.sh). Removing the double-queue stops the
    failures; truncating here stops the SUCCESS rows too, which were never
    part of the demo either.
    """
    from documents.models import PaperlessTask

    deleted, _ = PaperlessTask.objects.all().delete()
    print(f"  tasks: {deleted} build-time task row(s) truncated")


def truncate_history():
    """Empty the audit trail that BUILDING the estate produced.

    Every save above is an object-change record, and the demo's change log
    should start empty: it is a build-time audit trail, not part of the demo.
    Changes a user makes while exploring are logged normally.

    Guarded rather than assumed — the audit log is optional in Paperless and
    absent when PAPERLESS_AUDIT_LOG_ENABLED is off, and a seed that hard-fails
    on a disabled optional feature is a seed that breaks on someone else's
    configuration.
    """
    try:
        from auditlog.models import LogEntry
    except ImportError:
        print("  history: auditlog not installed, nothing to truncate")
        return
    deleted, _ = LogEntry.objects.all().delete()
    print(f"  history: {deleted} audit record(s) truncated")


def main():
    manifest = load_manifest()
    print("Building the frisian-mcp Paperless demo estate")

    with transaction.atomic():
        correspondents, types, tags, paths, fields = build_taxonomy(manifest)
        apply_documents(manifest, correspondents, types, tags, fields)
        build_saved_views(tags, types)
        build_workflow(tags)

    # Outside the transaction: these delete records the transaction above
    # created, and nothing after this point should be able to add more.
    truncate_build_tasks()
    truncate_history()
    print("Done.")


main()
