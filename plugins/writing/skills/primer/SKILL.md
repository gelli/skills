---
name: primer
description: Write a technical primer on a field, technology or system as a document — starts with a short orientation and adds detail section by section, for a competent reader new to the topic; for a system deployed here it also maps where each part lives and which parts work. Use when the user asks for a written explanation to keep or share (primer, explainer, executive summary, system overview); questions answered in chat stay in chat.
argument-hint: <topic> [for <audience>] [--depth summary|primer|deep]
---

# Technical primer

Write a **technical primer** on: $ARGUMENTS

A primer is for a competent reader who is new to *this* topic. It sits between an executive
summary and a textbook: the document you hand a strong colleague on their first day so they
can follow the conversation by lunch and make good decisions by the end of the week.

This skill decides what the document says and how it is built. Where it goes, and the
conventions of that place (frontmatter, link syntax, index entries, commits), come from the
request and the rules of the session; see §6.

## 1. Pin down the brief

Parse the arguments:

- **Topic**: what the primer covers. If it is ambiguous (e.g. "FHIR" could mean the standard
  or our FHIR server), make the most reasonable choice and state it in the opening section.
- **Kind**: decide whether the topic is a **system** (something deployed here: code, config,
  plugins, tools, services you can inspect and run) or an **external field or technology**.
  Systems get the map and status sections in §3.
- **Audience**: default is *"a senior software engineer from an adjacent domain"*. If the
  arguments say `for <audience>`, use that persona instead and calibrate depth to it:
  what can be assumed, which terms need defining, which details matter for *their* decisions.
  `for me` means the person asking; assume what this conversation and their setup show they
  know.
- **Depth**: `--depth summary|primer|deep`, default `primer`. Words such as "executive
  summary", "overview" or "short" in the request select `summary`; "in depth" or "everything"
  select `deep`. The sections each depth uses are in §3.

## 2. Research before writing

- **System**: follow it wherever it is deployed, beyond the current directory: user and
  project settings, installed plugins and their source repositories, hooks, config under home
  directories, binaries on the PATH, running services. For each part record where its source
  of truth lives and where it is installed or loaded from. Base the primer on observed
  behaviour, and note every place where it differs from the documented design.
- **Secrets**: config files often hold tokens, keys and passwords. Read them with a filter
  that drops secret fields, quote only field names, and never print a secret value.
- **External field or technology**: use context7 for library, framework, SDK and CLI
  behaviour; use web search for anything else that changes over time (standards status,
  versions, maintainers, adoption). Prefer primary sources such as specs, official docs and
  the original papers.
- **Existing documents**: find the guides, ADRs and manuals that already cover the topic.
  Link to them for usage detail, and keep the primer to what they lack.
- Collect the sources you actually used for the reading list at the end.

Write only once you can state the governing idea of the topic in two sentences.

## 3. Structure: inverted pyramid, increasing depth

Use the sections below in this order, adapting the headings to the topic. Depth must increase
from section to section, so a reader can stop after any section and still have a correct
picture at that level of detail.

1. **Orientation** (one short paragraph a reader takes in at a glance). What it is, what
   problem it solves, where it sits in the bigger picture, and the one thing to remember if
   the reader reads nothing else.
2. **Why it exists.** The problem, what came before, and what made the old way insufficient.
   Motivation makes the later design choices understandable.
3. **Mental model and core concepts.** The 4–8 concepts everything else builds on, and how
   they relate to each other. Add a diagram (Mermaid) when the relationships are structural.
4. **How it works.** The main mechanics: data flow, lifecycle, protocol, algorithm, or
   architecture. For systems, zoom in C4-style: context → containers → components, going only
   as deep as the reader needs.
5. **Map of the parts** (systems only). One table per group of parts, one row per part: what
   it does, source of truth, installed or loaded location, how it is reached (file, CLI, API,
   MCP, hook, UI). Add the resolution order of any setting that has fallbacks.
6. **Status as of <date>** (systems only). Three groups: verified by a real check in this
   session (name the check), configured and untested, configured and failing (name the
   symptom). Then **known drift**: numbered items where docs, config and behaviour disagree,
   each naming both sides. Report drift; leave the decision to the owner.
7. **In practice.** Trade-offs, typical failure modes, gotchas, performance and operational
   characteristics, common misconceptions, and what experienced practitioners know beyond
   the docs.
8. **Deep dives.** One subsection per area that deserves real detail: an important edge
   case, a tricky subsystem, a regulatory or security angle. Include one only where the
   detail changes how someone would work with or decide about the topic.
9. **Landscape.** Alternatives, competing approaches, related standards and technologies,
   and when you would pick each one.
10. **Glossary.** Every term of art used in the document, one line each.
11. **Further reading.** The sources used, plus the 3–5 best next reads, each with a
    one-line note on why it is worth reading.

Sections per depth:

| Depth | System | External topic | Length |
|---|---|---|---|
| `summary` | 1, 3, 4, 5, 6 | 1, 2, 3, 4, 9 | what a reader gets through in five minutes; sources as a short list |
| `primer` | 1–7, 9–11 | 1–4, 7, 9–11 | a first-day read: every included section in full, early sections short |
| `deep` | all | all except 5 and 6 | as long as the deep dives need |

Skip a section the depth includes only if it does not apply, and say so in one line.

## 4. Writing rules

- The writing rules of the active CLAUDE.md files apply and take precedence over this
  section (style bans, link rules, language).
- **Full technical depth.** Use the field's real terminology; define each term once, the
  first time it appears, and add it to the glossary.
- **Analogies only when they carry weight.** One good analogy for the mental model is enough;
  drop any analogy that breaks down under scrutiny.
- **Concrete examples.** Each core concept gets a short, realistic example (a message, a
  config snippet, a request/response, a worked number).
- **Each section stands on its own.** Begin each with a sentence that says what it covers,
  and avoid "as mentioned above" chains.
- **Honest about uncertainty.** Mark contested points, open questions and anything you
  could not verify. Never invent version numbers, dates or figures.
- **Proportionate length.** Breadth comes from the landscape and glossary, depth from the
  deep dives. Keep the early sections short.
- Prose by default; use tables for comparisons and maps, and lists only for things that
  are lists.

## 5. Check before finishing

- Read the orientation on its own: is it correct and useful without anything else?
- Does depth increase section by section, with detail kept out of the early sections?
- Is every term used defined somewhere, and is every factual claim either common knowledge
  for the stated audience or backed by a listed source?
- Systems: does every row of the map name a real location you inspected, and does every
  "verified" status name the check that ran?
- Do the Mermaid diagrams render (valid syntax)?
- No secret value appears anywhere in the output.

## 6. Hand-off

The primer consists of five parts, so whatever stores it can map each one to its own
conventions:

- **Title.**
- **Summary line**: one sentence on what the document covers, usable as an index entry.
- **Body**: the sections from §3, in Markdown.
- **Sources**: the list from §2, each a link or a path.
- **Drift**: the numbered known-drift items from the Status section (§3, item 6; systems only), for
  places that track contradictions separately.

Deliver it where the request or the session's rules say. Before writing, apply that
destination's conventions to the body (link syntax, frontmatter, diagram support) and
follow its storage rules (indexes, logs, commits). If nothing names a destination, return
the primer in the conversation and offer to save it.

Then report where it went and, in two or three sentences, the governing idea of the topic
and any areas where the sources were thin or contradictory. For a system, lead with the
drift item that most changes what the reader does next.
