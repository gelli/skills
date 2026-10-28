# writing

Skills for prose that people read, as opposed to documentation that machines or reviewers scan:

- **blog-post** drafts, outlines and revises technical blog posts on software, architecture and engineering topics.
- **primer** writes a technical primer on a field, technology or system: a short orientation first, then detail section by section, for a competent reader new to the topic. For a system deployed in the current environment it also maps where each part lives and which parts work.
- **writer** writes or rewrites copy (newsletters, landing pages, emails, social posts, announcements, essays) so it sounds conversational and human instead of corporate or generated. It hands technical blog posts to `writing:blog-post`.

## Install

```
/plugin marketplace add gelli/skills
/plugin install writing@gelli-skills
```

Invoke the skills as `/writing:blog-post`, `/writing:primer` and `/writing:writer`, or let Claude pick them from their descriptions.
