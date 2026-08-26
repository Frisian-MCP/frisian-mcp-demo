"""
Generate the demo document corpus.

Runs in a throwaway `python:3.12-slim` container with reportlab installed —
NOT on the maintainer's machine and NOT inside the Paperless image. That is
deliberate on both counts:

  * off the maintainer's machine, because a seed that depends on what happens
    to be installed locally produces a different estate in CI than it does on
    a laptop, and the difference shows up as a demo that "works for me"
  * out of the Paperless image, because reportlab is not one of Paperless's
    dependencies and adding a build-only package to a published runtime image
    to generate files once is the wrong shape

Usage:
    python3 corpus.py /out

Writes:
    /out/<nnn>-<slug>.pdf     the documents themselves
    /out/manifest.json        what each document is: correspondent, type,
                              tags, created date, custom field values

The PDFs are the ONLY thing Paperless consumes. The manifest is applied
afterwards by build_estate.py, because Paperless's own matching heuristics are
a demo of Paperless, not of frisian-mcp — and a corpus that is filed correctly
only when the classifier guesses right is not reproducible.

WHY BORN-DIGITAL PDFs
---------------------
Every page carries a real text layer, so `PAPERLESS_OCR_MODE=skip_text` has
nothing to do and consumption is seconds rather than minutes. Full-text search
still works — the text is genuinely there, it just did not have to be
recovered from pixels. Scanned-image PDFs would make the seed slow, the demo
slow to restart, and neither would demonstrate anything extra.

WHY THE OUTPUT IS BYTE-REPRODUCIBLE
-----------------------------------
`rl_config.invariant` strips the creation timestamp and the document ID that
reportlab otherwise randomises per run. Without it, every seed produces
different bytes, so every document gets a different checksum, so the estate
is different every time it is built — and "rebuild the estate" stops being a
safe thing to do.
"""

import json
import sys
from pathlib import Path

from reportlab import rl_config

# Must be set BEFORE the canvas module is imported: it is read at import time.
rl_config.invariant = 1

from reportlab.lib.pagesizes import LETTER  # noqa: E402
from reportlab.lib.units import inch  # noqa: E402
from reportlab.pdfgen import canvas  # noqa: E402

# ---------------------------------------------------------------------------
# The estate.
#
# Every value here is fiction. The correspondents, addresses, account numbers
# and amounts are invented for this demo and correspond to no real person or
# organisation — which is a requirement, not a stylistic choice, for a corpus
# published in a public image.
#
# It is shaped to make the permission demo legible rather than to be large:
# six correspondents, six document types, eight tags, and enough overlap
# between them that a filtered query returns something interesting.
# ---------------------------------------------------------------------------

CORRESPONDENTS = [
    "Northwind Utilities",
    "City of Ashford",
    "Vellum & Poole LLP",
    "Bluebird Mutual Insurance",
    "Harborview Family Clinic",
    "Cascade Freight Co.",
]

DOCUMENT_TYPES = ["Invoice", "Statement", "Letter", "Contract", "Receipt", "Report"]

TAGS = [
    ("paid", "#4caf50"),
    ("unpaid", "#f44336"),
    ("tax-2026", "#3f51b5"),
    ("warranty", "#ff9800"),
    ("medical", "#009688"),
    ("legal", "#795548"),
    ("urgent", "#e91e63"),
    ("archived", "#607d8b"),
]

STORAGE_PATHS = [
    ("By correspondent", "{correspondent}/{created_year}/{title}"),
    ("By year", "{created_year}/{correspondent}/{title}"),
    ("Legal hold", "legal-hold/{created_year}/{correspondent}-{title}"),
]

# (name, data_type). Paperless's data types are strings on the model.
CUSTOM_FIELDS = [
    ("Account number", "string"),
    ("Amount due", "monetary"),
    ("Due date", "date"),
]

# ---------------------------------------------------------------------------
# The documents.
#
# (title, correspondent, doc_type, created, tags, body_lines, custom)
#
# `created` is the document date Paperless files it under, not the consumption
# date. Spread across two years so date filters and the "this year" saved view
# return a subset rather than everything.
# ---------------------------------------------------------------------------

DOCUMENTS = [
    (
        "Electricity invoice January 2026",
        "Northwind Utilities",
        "Invoice",
        "2026-01-14",
        ["unpaid", "urgent"],
        [
            "Service address: 118 Wetherby Lane, Ashford",
            "Meter reading (previous): 41,882 kWh",
            "Meter reading (current):  42,447 kWh",
            "Consumption this period:     565 kWh",
            "",
            "Standing charge                     18.40",
            "Energy charge 565 kWh @ 0.2140      120.91",
            "Late payment fee                      9.00",
            "",
            "TOTAL DUE                           148.31",
            "",
            "Payment is overdue. A disconnection notice will follow if this",
            "balance is not settled within fourteen days of the date above.",
        ],
        {"Account number": "NU-4471-9920", "Amount due": "148.31", "Due date": "2026-02-01"},
    ),
    (
        "Electricity invoice December 2025",
        "Northwind Utilities",
        "Invoice",
        "2025-12-12",
        ["paid"],
        [
            "Service address: 118 Wetherby Lane, Ashford",
            "Consumption this period:     612 kWh",
            "",
            "Standing charge                     18.40",
            "Energy charge 612 kWh @ 0.2140      130.97",
            "",
            "TOTAL DUE                           149.37",
            "",
            "Paid in full by direct debit on 2025-12-28. Thank you.",
        ],
        {"Account number": "NU-4471-9920", "Amount due": "149.37", "Due date": "2025-12-30"},
    ),
    (
        "Electricity invoice November 2025",
        "Northwind Utilities",
        "Invoice",
        "2025-11-13",
        ["paid", "archived"],
        [
            "Service address: 118 Wetherby Lane, Ashford",
            "Consumption this period:     498 kWh",
            "",
            "TOTAL DUE                           124.98",
            "",
            "Paid in full by direct debit on 2025-11-29. Thank you.",
        ],
        {"Account number": "NU-4471-9920", "Amount due": "124.98", "Due date": "2025-11-30"},
    ),
    (
        "Annual consumption statement 2025",
        "Northwind Utilities",
        "Statement",
        "2026-01-31",
        ["tax-2026"],
        [
            "Account NU-4471-9920 — summary for the calendar year 2025.",
            "",
            "Total consumption           6,884 kWh",
            "Total billed                 1,472.60",
            "Average monthly bill           122.72",
            "Highest month              March (742 kWh)",
            "Lowest month               July (388 kWh)",
            "",
            "This statement is provided for your records and may be required",
            "when claiming a home-office deduction.",
        ],
        {"Account number": "NU-4471-9920"},
    ),
    (
        "Property tax assessment 2026",
        "City of Ashford",
        "Statement",
        "2026-02-03",
        ["tax-2026", "unpaid"],
        [
            "Parcel: 04-118-0027",
            "Assessed value                    412,000",
            "Millage rate                       0.01184",
            "",
            "Annual tax                        4,878.08",
            "First instalment due 2026-03-31    2,439.04",
            "Second instalment due 2026-09-30   2,439.04",
            "",
            "Appeals must be filed with the Board of Review within thirty days.",
        ],
        {"Account number": "04-118-0027", "Amount due": "2439.04", "Due date": "2026-03-31"},
    ),
    (
        "Refuse collection schedule change",
        "City of Ashford",
        "Letter",
        "2026-01-08",
        [],
        [
            "Dear Resident,",
            "",
            "Effective 2026-02-01, refuse and recycling collection for the",
            "Wetherby Lane district moves from Tuesday to Thursday.",
            "",
            "Bins should be at the kerb by 06:00. Garden waste collection",
            "resumes on 2026-03-05 and runs fortnightly until November.",
            "",
            "No action is required on your part.",
        ],
        {},
    ),
    (
        "Building permit approval",
        "City of Ashford",
        "Letter",
        "2025-08-19",
        ["archived"],
        [
            "Permit BP-2025-1184 has been APPROVED.",
            "",
            "Scope: replacement of rear conservatory glazing, no change to",
            "footprint or drainage.",
            "",
            "Conditions:",
            "  1. Work to be completed within 24 months of this notice.",
            "  2. Inspection required before the glazing is sealed.",
            "  3. Waste to be removed to a licensed facility.",
            "",
            "This approval does not constitute a certificate of occupancy.",
        ],
        {"Account number": "BP-2025-1184"},
    ),
    (
        "Engagement letter — estate planning",
        "Vellum & Poole LLP",
        "Contract",
        "2025-09-02",
        ["legal"],
        [
            "This letter confirms the terms on which Vellum & Poole LLP will",
            "act in connection with the preparation of your will and lasting",
            "powers of attorney.",
            "",
            "Scope of work",
            "  - Initial consultation and instruction taking",
            "  - Drafting of the will and two powers of attorney",
            "  - One round of revisions",
            "  - Attendance at execution",
            "",
            "Fees",
            "  Fixed fee of 1,850.00 plus disbursements, payable on completion.",
            "",
            "Either party may terminate this engagement in writing at any time.",
        ],
        {"Account number": "VP-2025-0417", "Amount due": "1850.00"},
    ),
    (
        "Fee note — estate planning",
        "Vellum & Poole LLP",
        "Invoice",
        "2025-11-21",
        ["legal", "paid"],
        [
            "Matter VP-2025-0417 — preparation of will and powers of attorney.",
            "",
            "Professional fees                  1,850.00",
            "Land registry disbursement            42.00",
            "",
            "TOTAL                              1,892.00",
            "",
            "Settled by bank transfer 2025-12-04.",
        ],
        {"Account number": "VP-2025-0417", "Amount due": "1892.00", "Due date": "2025-12-05"},
    ),
    (
        "Executed will and testament",
        "Vellum & Poole LLP",
        "Contract",
        "2025-11-18",
        ["legal", "archived"],
        [
            "EXECUTED COPY — retained for the client's records.",
            "",
            "The original of this instrument is held in the firm's deed store",
            "under reference VP-DS-2025-0417. A copy has been lodged with the",
            "named executors.",
            "",
            "This document supersedes all prior testamentary instruments.",
            "",
            "Signed and witnessed 2025-11-18 at the offices of Vellum & Poole",
            "LLP in the presence of two independent witnesses.",
        ],
        {"Account number": "VP-DS-2025-0417"},
    ),
    (
        "Home insurance renewal 2026",
        "Bluebird Mutual Insurance",
        "Statement",
        "2026-02-11",
        ["unpaid"],
        [
            "Policy BM-88-204417 — buildings and contents.",
            "",
            "Your policy renews on 2026-03-15.",
            "",
            "Buildings sum insured            520,000",
            "Contents sum insured              65,000",
            "Accidental damage                 included",
            "Voluntary excess                     250",
            "",
            "Annual premium                    684.20",
            "",
            "No claims have been made in the last five years.",
        ],
        {"Account number": "BM-88-204417", "Amount due": "684.20", "Due date": "2026-03-15"},
    ),
    (
        "Claim settlement — storm damage",
        "Bluebird Mutual Insurance",
        "Letter",
        "2025-10-30",
        ["paid", "archived"],
        [
            "Claim BM-CL-25-3391 has been settled.",
            "",
            "Reported damage: displaced ridge tiles and guttering following",
            "the storm of 2025-10-04.",
            "",
            "Assessed repair cost              3,140.00",
            "Less policy excess                  250.00",
            "",
            "SETTLEMENT PAID                   2,890.00",
            "",
            "Payment was made to your nominated account on 2025-10-29. This",
            "claim will be reflected in your next renewal quotation.",
        ],
        {"Account number": "BM-88-204417", "Amount due": "2890.00"},
    ),
    (
        "Appliance warranty certificate",
        "Bluebird Mutual Insurance",
        "Contract",
        "2025-06-14",
        ["warranty"],
        [
            "Extended warranty certificate — five years from purchase.",
            "",
            "Covered item     Condensing boiler, model HX-240",
            "Serial           HX240-2025-88134",
            "Installed        2025-06-02",
            "Cover ends       2030-06-02",
            "",
            "Cover includes parts, labour and annual servicing. It excludes",
            "damage caused by the failure to have the appliance serviced",
            "annually by an approved engineer.",
        ],
        {"Account number": "HX240-2025-88134"},
    ),
    (
        "Annual physical results",
        "Harborview Family Clinic",
        "Report",
        "2026-01-27",
        ["medical"],
        [
            "Patient reference HFC-20114.",
            "",
            "All measured values are within the expected reference range.",
            "",
            "Blood pressure           118/74 mmHg",
            "Resting heart rate           62 bpm",
            "Total cholesterol           4.4 mmol/L",
            "HbA1c                        34 mmol/mol",
            "",
            "Recommendation: no clinical follow-up required. Repeat in twelve",
            "months.",
        ],
        {"Account number": "HFC-20114"},
    ),
    (
        "Vaccination record",
        "Harborview Family Clinic",
        "Report",
        "2025-10-09",
        ["medical", "archived"],
        [
            "Patient reference HFC-20114.",
            "",
            "Seasonal influenza vaccine administered 2025-10-09.",
            "Batch FLU-25-8841. Left deltoid. No adverse reaction observed",
            "during the fifteen-minute observation period.",
            "",
            "Next due: autumn 2026.",
        ],
        {"Account number": "HFC-20114"},
    ),
    (
        "Clinic invoice — annual physical",
        "Harborview Family Clinic",
        "Invoice",
        "2026-01-27",
        ["medical", "paid"],
        [
            "Patient reference HFC-20114.",
            "",
            "Comprehensive physical examination      210.00",
            "Laboratory panel                         88.00",
            "",
            "TOTAL                                   298.00",
            "",
            "Paid at time of service by card.",
        ],
        {"Account number": "HFC-20114", "Amount due": "298.00", "Due date": "2026-01-27"},
    ),
    (
        "Referral letter — physiotherapy",
        "Harborview Family Clinic",
        "Letter",
        "2025-07-22",
        ["medical", "archived"],
        [
            "Dear Colleague,",
            "",
            "I would be grateful if you would see this patient regarding a",
            "six-week history of right shoulder impingement, unresponsive to",
            "rest and non-steroidal anti-inflammatories.",
            "",
            "There is no history of trauma. Imaging has not been performed.",
            "",
            "Patient reference HFC-20114.",
        ],
        {"Account number": "HFC-20114"},
    ),
    (
        "Freight invoice — pallet delivery",
        "Cascade Freight Co.",
        "Invoice",
        "2026-02-06",
        ["unpaid"],
        [
            "Consignment CF-2026-11482.",
            "",
            "Collection      Ashford depot, 2026-02-04",
            "Delivery        118 Wetherby Lane, 2026-02-06",
            "Weight          412 kg on two pallets",
            "",
            "Line haul                            318.00",
            "Tail lift surcharge                   45.00",
            "Fuel surcharge                        28.62",
            "",
            "TOTAL DUE                            391.62",
            "",
            "Payment terms: 30 days from invoice date.",
        ],
        {"Account number": "CF-88204", "Amount due": "391.62", "Due date": "2026-03-08"},
    ),
    (
        "Proof of delivery CF-2026-11482",
        "Cascade Freight Co.",
        "Receipt",
        "2026-02-06",
        [],
        [
            "Consignment CF-2026-11482 delivered 2026-02-06 at 11:42.",
            "",
            "Two pallets, 412 kg, received in good condition.",
            "Signed at the point of delivery.",
            "",
            "Any damage must be reported within three working days.",
        ],
        {"Account number": "CF-88204"},
    ),
    (
        "Freight invoice — return collection",
        "Cascade Freight Co.",
        "Invoice",
        "2025-12-19",
        ["paid"],
        [
            "Consignment CF-2025-10904.",
            "",
            "Line haul                            212.00",
            "Fuel surcharge                        19.08",
            "",
            "TOTAL DUE                            231.08",
            "",
            "Settled 2026-01-12.",
        ],
        {"Account number": "CF-88204", "Amount due": "231.08", "Due date": "2026-01-18"},
    ),
    (
        "Terms of carriage 2026",
        "Cascade Freight Co.",
        "Contract",
        "2026-01-02",
        ["legal"],
        [
            "These conditions govern all consignments carried on or after",
            "2026-01-01 and supersede the 2024 edition.",
            "",
            "Liability is limited to 22.00 per kilogram of the gross weight of",
            "the consignment unless a higher value is declared in advance and",
            "the corresponding premium paid.",
            "",
            "Claims for loss or damage must be notified in writing within",
            "three working days of delivery, and in any event within",
            "twenty-eight days of collection.",
        ],
        {"Account number": "CF-88204"},
    ),
    (
        "Hardware store receipt",
        "Cascade Freight Co.",
        "Receipt",
        "2025-06-02",
        ["warranty", "archived"],
        [
            "Retained as proof of purchase for the boiler warranty.",
            "",
            "Condensing boiler HX-240             2,140.00",
            "Installation kit                       118.00",
            "Extended warranty (5 yr)               240.00",
            "",
            "TOTAL                                2,498.00",
            "",
            "Serial HX240-2025-88134. Keep this receipt for the duration of",
            "the warranty period.",
        ],
        {"Amount due": "2498.00"},
    ),
    (
        "Water rates statement 2026",
        "City of Ashford",
        "Statement",
        "2026-01-21",
        ["tax-2026", "unpaid"],
        [
            "Parcel 04-118-0027 — metered supply.",
            "",
            "Previous reading      2,884 m3",
            "Current reading       2,951 m3",
            "Consumption              67 m3",
            "",
            "Volumetric charge                    148.74",
            "Standing charge                       64.00",
            "Surface water drainage                41.20",
            "",
            "TOTAL DUE                            253.94",
        ],
        {"Account number": "04-118-0027", "Amount due": "253.94", "Due date": "2026-02-28"},
    ),
    (
        "Boiler service report 2026",
        "Northwind Utilities",
        "Report",
        "2026-02-17",
        ["warranty", "urgent"],
        [
            "Annual service — condensing boiler HX-240, serial",
            "HX240-2025-88134.",
            "",
            "Flue gas analysis            PASS",
            "Gas tightness test           PASS",
            "Condensate drainage          PASS",
            "Expansion vessel pressure    LOW — recharged to 1.0 bar",
            "",
            "ADVISORY: the pressure relief discharge pipe terminates within",
            "500 mm of an opening window and should be re-routed. This does",
            "not affect the warranty provided it is corrected before the next",
            "annual service.",
        ],
        {"Account number": "HX240-2025-88134"},
    ),
]


def slugify(title):
    """Filesystem-safe, stable slug. Not user-visible."""
    out = []
    for ch in title.lower():
        if ch.isalnum():
            out.append(ch)
        elif out and out[-1] != "-":
            out.append("-")
    return "".join(out).strip("-")


def render(path, title, correspondent, doc_type, created, body_lines):
    """Write one born-digital PDF with a real text layer."""
    c = canvas.Canvas(str(path), pagesize=LETTER)
    # Belt and braces alongside rl_config.invariant: the metadata below is what
    # Paperless reads for its own hints, and it must not vary per run.
    c.setTitle(title)
    c.setAuthor(correspondent)
    c.setSubject(doc_type)

    width, height = LETTER
    left = inch
    y = height - inch

    c.setFont("Helvetica-Bold", 16)
    c.drawString(left, y, correspondent)
    y -= 0.32 * inch

    c.setFont("Helvetica-Bold", 12)
    c.drawString(left, y, title)
    y -= 0.24 * inch

    c.setFont("Helvetica", 9)
    c.drawString(left, y, f"{doc_type} — {created}")
    y -= 0.16 * inch

    c.setLineWidth(0.5)
    c.line(left, y, width - inch, y)
    y -= 0.32 * inch

    c.setFont("Helvetica", 10)
    for line in body_lines:
        if y < inch:
            c.showPage()
            c.setFont("Helvetica", 10)
            y = height - inch
        c.drawString(left, y, line)
        y -= 0.19 * inch

    c.setFont("Helvetica-Oblique", 7)
    c.drawString(
        left,
        0.6 * inch,
        "Synthetic document generated for the frisian-mcp demo. "
        "Not a real record of any real person or organisation.",
    )
    c.showPage()
    c.save()


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <output-dir>", file=sys.stderr)
        return 2

    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)

    manifest = {
        "correspondents": CORRESPONDENTS,
        "document_types": DOCUMENT_TYPES,
        "tags": [{"name": n, "colour": c} for n, c in TAGS],
        "storage_paths": [{"name": n, "path": p} for n, p in STORAGE_PATHS],
        "custom_fields": [{"name": n, "data_type": t} for n, t in CUSTOM_FIELDS],
        "documents": [],
    }

    for index, (title, corr, dtype, created, tags, body, custom) in enumerate(
        DOCUMENTS, start=1
    ):
        filename = f"{index:03d}-{slugify(title)}.pdf"
        render(out / filename, title, corr, dtype, created, body)
        manifest["documents"].append(
            {
                "filename": filename,
                "title": title,
                "correspondent": corr,
                "document_type": dtype,
                "created": created,
                "tags": tags,
                "custom_fields": custom,
            }
        )

    (out / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    print(f"wrote {len(DOCUMENTS)} documents + manifest.json to {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
