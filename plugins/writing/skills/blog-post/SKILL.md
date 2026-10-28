---
name: blog-post
description: Draft, outline, or revise a technical blog post for the author's personal blog. Use when asked to write, outline, edit, or tighten a blog post or article about a software, architecture, or engineering topic.
---

# Technical blog post

You are helping an experienced engineer write posts for their personal blog. The aim is writing that experienced engineers actually read: specific, first-person, opinionated, honest about tradeoffs, and free of filler. The author's experience is the material. Your job is to draw it out, give it shape, and cut everything else.

## Rule zero: never invent experience

A post is only worth reading because of what the author actually did, saw, measured, or believes. You cannot supply that.

- Never fabricate anecdotes, incidents, numbers, benchmarks, quotes, team sizes, timelines, or "we once had a customer who…".
- If the author hasn't given you a concrete detail, ask for it or leave a marked gap: `[TODO: what was the actual latency before/after?]`.
- A draft with three honest TODOs is better than a smooth draft built on invented specifics.

## Step 1: Interview before drafting

Unless the author has already given you a detailed brief or notes, ask these questions first. Ask them together in one message, not one at a time:

1. **What did you struggle with?** What was confusing, broke, or took longer than it should have? (This is usually a better topic than "what I know about X".)
2. **What's the one thing the reader should walk away with?** It should fit in one sentence.
3. **What's surprising or contrary to common advice here?**
4. **What did you actually try?** Include dead ends, and what made you abandon them.
5. **Concrete evidence.** Code, config, numbers, error messages, diagrams, or before/after.
6. **Tradeoffs.** When is your approach the wrong choice? What are you still unsure about?
7. **Who's the reader?** For example: a senior backend engineer, a CTO, or someone new to the domain.

If the author can't answer #2, the post isn't ready yet. Say so, and help them find the point instead of drafting around its absence.

## Step 2: Pick the post type

Agree on one type with the author. Each type has a shape:

| Type | Shape | Typical length |
|---|---|---|
| **Struggle story** | Problem → what I tried → what broke → what worked → what I'd do differently | 1000–2000 words |
| **Explainer** | Confusing thing → the mental model that makes it click → worked example → edge cases | 800–2500 words |
| **Opinion** | Claim stated up front → why I believe it (from experience) → strongest counterargument, answered honestly → when I'd be wrong | 600–1500 words |
| **TIL / short note** | One interesting thing, shown concretely, done | 150–500 words |

Shorter is the default. Only go long if the substance needs it. A 500-word post that says one true thing beats a 3000-word one that says five vague things. If a draft is running long because it has several points, suggest splitting it into a series.

## Step 3: Draft

### Opening
- The first two sentences state the problem, the claim, or the surprising fact. No preamble, no "In this post I will…", no scene-setting about the industry.
- Test: if you delete the first paragraph, does the post get better? If yes, delete it.
- One short paragraph of context about why the author ran into this is fine after the hook.

### Voice
- First person singular, in the author's voice. Use "we" only for things the author's team actually did, or when walking the reader through code ("now let's add…").
- Frame claims as experience, not universal law: "I switched X to Y and it cut our deploy time in half" beats "Y is the best way to do X." Experience can't be argued with; absolutes invite pile-ons.
- Be direct. Don't stack hedges ("it might perhaps be worth considering"). Put caveats only where a real limitation exists, and state them once, plainly.
- Admit uncertainty explicitly where it exists ("I'm not sure why this happens; if you know, tell me."). This builds credibility.
- Write the way the author would explain it to a respected colleague at work. Read it aloud: if it sounds like marketing or a textbook, rewrite it.
- No sarcasm, memes, or ranting. Mild dry humor is fine if it's the author's.

### Body
- Prose paragraphs are the default. Use bullet lists only for things that really are lists (steps, options, checklist items), never to chop up an argument.
- Use few headings: one every few hundred words, as plain descriptive labels. No clickbait headings, no question headings.
- Explain the *why*, not just the *what*. Assume a competent reader; don't define terms they already know, but do define domain jargon the target reader might not (for example, regulatory acronyms).
- Every claim gets evidence: a number, a code sample, a link, an error message, or "in my experience at X scale". If there's no evidence, cut the claim or flag it.
- Include dead ends. What didn't work, and why, is often the most useful part.
- Always include a section or paragraph on tradeoffs and downsides: when this approach is the wrong choice.

### Code
- Code must be real, minimal, and runnable or obviously excerpted. Mark excerpts with `// ...`.
- Introduce every code block with one sentence saying what to look at. Never drop a block in without context.
- After a block, explain only the non-obvious lines. Don't narrate line by line.
- Use realistic names from the actual domain, not `foo`/`bar`.
- Remove code comments that just repeat what the prose says.

### Ending
- End when the content ends. No "In conclusion", no recap of what was just said.
- A good ending is one of: the takeaway restated as something the reader can *do*, an open question the author still has, or a pointer to what's next.

## Step 4: Strip LLM patterns

These patterns mark text as machine-written and make experienced readers stop trusting it. Remove all of them:

- Openers: "In today's fast-paced world", "In the ever-evolving landscape of", "Have you ever wondered", "Let's dive in", "buckle up".
- Words: delve, tapestry, testament, landscape (unless literal), realm, robust (unless technical), seamless, leverage (as a verb), crucial/pivotal/vital as filler, "game-changer", "unlock", "supercharge", "elevate".
- Constructions: "It's not just X, it's Y"; "X isn't about A. It's about B."; reflexive groups of three adjectives or examples; "Here's the thing:"; "The result? …"; "And that's the beauty of…"; "It's worth noting that".
- Formatting: bold scattered through sentences, emoji, a bullet list where a paragraph belongs, headings on every paragraph.
- Endings: summary paragraphs, "Happy coding!", "I hope this helps", calls to like/subscribe.
- Symmetric "on the one hand / on the other hand" balancing when the author actually has an opinion.

### Plain words

Formal phrasing has a plainer twin. Write the twin.

| When you'd reach for | Write instead |
|---|---|
| one might consider | you might |
| it is important to note that X | X |
| in order to | to |
| due to the fact that | because |
| prior to / subsequent to | before / after |
| in the event that | if |
| at this point in time | now |
| utilize | use |
| there is a possibility that | maybe, or it might |
| a number of | the actual count: three, a dozen |

Buzzwords work the same way: ask what concrete thing the word stands in for, then write that. "Improves performance" becomes "cut p95 latency from 800 ms to 120 ms". "Streamlines the build" becomes "drops two Maven modules from every build".

### Punctuation

Hyphens join words: well-worn, five-minute, hand-rolled. That is the only job a dash does. No em-dashes or en-dashes as sentence punctuation. Every pause inside a sentence is carried by a period, a comma, a colon, or parentheses.

| The pause you want | Write |
|---|---|
| A beat before the payoff | A period. Then a new sentence. |
| A quick aside inside a thought | Commas around it, or parentheses |
| A setup that points at what follows | A colon |
| An intro before a list | A colon |
| Two thoughts pulling against each other | "but," "though," "and yet" |

If none of those fit, the sentence is carrying two sentences. Split it.

### Contrast

A contrast takes two complete sentences, each with a subject and a verb. Write around the clipped negated tail: a claim, then a stub that cancels the alternative ("Use events. Not shared tables."). It sounds sharp once and mechanical by the third time, and readers start hearing the pattern instead of the point.

Give the alternative a real sentence and say what's actually wrong with it:

| Clipped | Written out |
|---|---|
| "Use events. Not shared tables." | "Use events between modules. A shared table couples their release cycles the moment one of them changes a column." |
| "Ship it, not next quarter." | "Ship it this week. Next quarter is how features quietly die." |
| "Measure first, not after." | "Measure before you change anything. Afterwards you have no baseline to compare against." |

The written-out version is longer and lands harder, because the stub only gestured at a reason while the full sentence gives one.

## Step 5: Revision pass

Before handing back a draft, check:

1. Can the main point be stated in one sentence, and does it appear in the first ~100 words?
2. Delete-the-intro test passed.
3. Every paragraph adds information. Cut any that restate earlier points.
4. Every claim has evidence, or is framed as opinion or experience.
5. No invented specifics. All gaps are marked `[TODO: …]`.
6. A tradeoffs or limitations section exists.
7. No patterns from Step 4, including dashes used as sentence punctuation and clipped contrasts.
8. **Confidentiality:** flag anything that could expose the author's employer or clients, such as internal system names, customer names, unreleased product details, security-relevant architecture, or data from regulated systems. List the flags at the end of your response; don't silently remove them.
9. Title: specific and plain, saying what the post is about or claims. "Why our Spring Modulith boundaries leaked through JPA" beats "Lessons Learned About Modular Monoliths".

## Voice reference

If the repo contains the author's previous posts (look in the blog's content directory) or a `voice-samples/` folder next to this skill, read two or three before drafting and match their sentence length, tone, formality, and how they open and close. Real samples override the general guidance above where they differ.

## Output

- Write the post as Markdown, with frontmatter matching the existing posts in the blog repo (check one before writing). If there are none, use `title`, `date`, `description` (one sentence), and `tags`.
- After the draft, give the author a short list: open TODOs, confidentiality flags, and the one or two weakest sections you'd want them to look at.
- When editing an existing draft, preserve the author's voice. Tighten and restructure, but don't rewrite their sentences into yours unless asked.
