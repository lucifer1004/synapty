#!/usr/bin/env python3
"""Mechanical checks on governance prose.

WHY THIS EXISTS. Twelve independent reviews of RFC-0009 named seven
classes of defect. Two of them — text damaged by an edit, and a citation
pointing at a clause that does not carry what the citation promises —
are the only two a machine can find, and between them they accounted for
more critical findings than any other cause. A reviewer who spends a
pass re-reading for a severed sentence is a reviewer not spending it on
the six classes only a reader can find.

TWO KINDS OF OUTPUT, deliberately separated. DAMAGE is unambiguous and
fails: a sentence cannot half-exist. REVIEW is advisory and never fails,
because the corpus contains deliberate instances of every pattern here —
RFC-0009 decided in as many words that a frame citation names the clause
requiring the ACT rather than one naming the frame, so flagging those as
errors would train the reader to ignore the tool.

Reads gov/ as text on purpose: it is checking the source of truth for
damage, which is the one job the rendering path cannot do for it.
"""
import re
import sys
import glob
import collections

CLAUSE_GLOB = "gov/*/*/clauses/*.toml"


def clause_text(path):
    raw = open(path).read()
    if 'text = """' not in raw:
        return None
    return raw.split('text = """')[-1].rsplit('"""', 1)[0]


def sentences(flat):
    return [s.strip() for s in re.split(r"(?<=[.])\s+", flat) if len(s.strip()) > 60]


def find_damage(name, flat, raw_lines):
    out = []
    # A replacement that severed the sentence it landed in leaves a
    # connector with nothing before it. Only the coordinators and a bare
    # modal: "X: which agent, which tool" and "X: because Y" are ordinary
    # English, and flagging them taught nothing except to ignore the tool.
    for m in re.finditer(r"[^.]{0,90}:\s+(?:and|or|but|MUST|MAY|SHOULD)\b", flat):
        out.append(("severed sentence", m.group(0)[-95:]))
    # A sentence that ends on a word that cannot end one.
    for m in re.finditer(r"[^.]{0,90}\b(?:the|a|an|of|to|is|are|and|or|that|which|its)\s*$", flat):
        out.append(("truncated", m.group(0)[-95:]))
    for s in sentences(flat):
        if s.rstrip().endswith(("—", ",", "-")):
            out.append(("ends mid-thought", s[-95:]))
    # A replacement that ran out before its sentence did leaves a lower-case
    # word running straight into a capitalised one with no punctuation. This
    # got past a careful reading and every check above.
    #
    # PER LINE, not over the flattened text: a markdown heading is its own
    # line, and flattening ran "## Why one table" into the sentence after it
    # ten times over. Losing a break that spans a wrap is the price.
    for line in raw_lines:
        if line.lstrip().startswith("#"):
            continue
        for m in re.finditer(r"\b[a-z]{3,}\s+(?:Without|And|But|This|That|These|Those|It|They)\s+[a-z]", line):
            out.append(("two sentences run together — a replacement fell short",
                        line.strip()[max(0, m.start() - 50):m.end() + 25]))
    # The same sentence pasted twice is the commonest edit wreckage.
    for s, n in collections.Counter(sentences(flat)).items():
        if n > 1:
            out.append((f"repeated {n}x", s[:95]))
    return out


def find_review(name, flat, corpus):
    out = []
    # A citation that promises a name the cited clause does not carry.
    # Deliberate in places; a reader still has to decide, so it is listed.
    for m in re.finditer(r"`([a-z_]{4,})`\s*\(\[\[(RFC-\d{4})\]\]\s+(C-[A-Z-]+)", flat):
        frame, rfc, clause = m.groups()
        target = corpus.get((rfc, clause))
        if target is None:
            out.append(("cites a clause that does not exist", f"{frame} -> {rfc} {clause}"))
        elif frame not in target:
            out.append(("cited clause does not carry the name", f"{frame} -> {rfc} {clause}"))
    # An announcement about a change elsewhere outlives the change — but only
    # when it is still written as something to be done. A clause that says
    # the amendment WAS made, and what the receiving clause now reads, is a
    # record rather than a promise, and flagging it taught nobody anything:
    # the first version of this check reported four such records and one
    # real one, which is the ratio at which a check starts being ignored.
    for m in re.finditer(
        r".{0,110}(?:in the same change|is corrected here|is amended here).{0,60}", flat
    ):
        span = " ".join(m.group(0).split())
        if re.search(r"\bwas\b|\bwere\b|\bhave been\b|\bhas been\b|\blanded\b|\bnow reads\b", span):
            continue
        out.append(("announces a change elsewhere — check it landed", span[:110]))
    # A reference by POSITION breaks when anything is inserted between.
    # Both instances that got past a careful reading in this corpus were
    # of this shape: "the last one" after a frame was appended to the
    # list, and "four sentences earlier" after a sentence was added.
    for m in re.finditer(
        r".{0,70}\b(?:the last one|the (?:first|second|third|last) of (?:these|those)"
        r"|\w+ sentences? (?:earlier|above|below)|\w+ bullets? (?:up|down|above|below)"
        r"|the bullet above|the paragraph above|the sentence above).{0,50}", flat):
        out.append(("refers by position — an insertion moves it", " ".join(m.group(0).split())[:110]))
    return out


# A check that did not earn its place, recorded so it is not rebuilt:
# "a normative sentence about a field/flag/frame/capability with no
# backticked name in it" targets a real defect — three of the twelfth
# review's findings were an obligation with nothing to spell — but the
# words it keys on are used generically all over the corpus, and it
# produced sixty-two advisories against three real cases. Detecting the
# ABSENCE of a name needs to know which nouns are wire things, and that
# is a reader's judgement.


def main():
    corpus = {}
    for path in glob.glob(CLAUSE_GLOB):
        t = clause_text(path)
        if t is None:
            continue
        parts = path.split("/")
        corpus[(parts[2], parts[4][:-5])] = " ".join(t.split())

    damage, review = [], []
    for path in sorted(glob.glob(CLAUSE_GLOB)):
        t = clause_text(path)
        if t is None:
            continue
        # DEPRECATED CLAUSES ARE HISTORY AND ARE NOT EDITED, so reporting
        # them is reporting work nobody may do. Five such findings sat in
        # every run of this script, which is how a report stops being read.
        # They still populate the corpus above: a live clause citing one is
        # a finding about the LIVE clause.
        if re.search(r'^\s*status\s*=\s*"deprecated"', open(path).read(), re.M):
            continue
        name = "/".join(path.split("/")[2::2]).replace(".toml", "")
        flat = " ".join(t.split())
        damage += [(name, k, v) for k, v in find_damage(name, flat, t.splitlines())]
        review += [(name, k, v) for k, v in find_review(name, flat, corpus)]

    for name, kind, snippet in review:
        print(f"review  {name}: {kind}\n          {snippet}")
    if review:
        print()
    for name, kind, snippet in damage:
        print(f"DAMAGE  {name}: {kind}\n          {snippet}")

    print(f"\n{len(damage)} damage, {len(review)} to review, over {len(corpus)} clauses")
    return 1 if damage else 0


if __name__ == "__main__":
    sys.exit(main())
