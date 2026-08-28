# About Me

[FlashOS](../README.md) › [Product Guide](README.md) › About Me

I am Anton, a computer science student and the maintainer of FlashOS. The
project began with a desire to learn. I have always learned best by making
things, and an operating system gave me more than enough to explore.

One question lies behind much of what I build: **How would I do it?** I like
taking a system apart in my mind, examining the assumptions behind it, and
deciding how its pieces should fit together. FlashOS is where I try to answer
that question.

It brings together many of the things I enjoy about computer science:
operating systems, language design, architecture, tools, and testing. More
importantly, it gives me the freedom to follow an idea from its first outline
to something I can run, test, and improve.

## The system I wanted to build

As I learned more about computer science, I found myself spending more time in
the terminal. Eventually it became the way I preferred to use a computer. I do
not think graphical interfaces are bad. I simply do not enjoy using them, and
I rarely need one for my own work.

Leaving out a graphical desktop and mouse-driven interaction means there is
less for me to build and maintain. Building an operating system already takes
a great deal of time. A keyboard-first, text-based environment gives me what I
need without adding an interface I would not use.

FlashOS is text-based today. A richer terminal interface may come later, but it
does not ship yet.

## Why Flash matters to me

Flash is where the operating-system project and language design meet. A command
typed at the prompt and a program saved in a file should not feel like two
separate worlds. Flash gives them the same language and the same way of dealing
with values, processes, statuses, and jobs.

This technical choice is also a personal one. I prefer systems whose parts
have clear responsibilities and fit together in a way I can understand. I do
not want complexity for its own sake, and I do not need a terminal interface
to be elaborate. I want the language and the system around it to give me
structure without hiding what they are doing.

FlashOS is still pre-alpha software. Much of the larger terminal-interface
idea remains unbuilt. Those plans matter to me, but they are plans rather than
claims about what FlashOS can do today.

## How I work

My work may begin with an idea of my own or with something I encounter
elsewhere. Before deciding what to build, I study how other people have
approached the same problem. I am interested in the parts of an argument that
remain useful even when I disagree with its conclusion.

Once I know what I want the result to be, I work backwards. I identify what is
essential, sketch the architecture, and break the goal into smaller plans.
Those plans form a tree, with broad questions near the top and concrete work at
the leaves. The structure changes when it needs to, but I try to make those
changes deliberately. I would rather reconsider a weak decision than cover it
with another patch.

Tests grow alongside the implementation. I add them while building a feature
and strengthen them afterward, when the gaps are easier to see. I also try to
be precise about what each test proves. Passing a source check does not prove
that a target builds. A successful build does not prove that an image boots,
and a virtual-machine run does not tell me how the same system behaves on a
physical device. Keeping those claims separate makes it easier to be honest
about what has actually been tested.

I have taken a similar approach to the working system behind FlashOS. The
knowledge stays human-readable, and each fact or decision has a clear home.
Current state is kept apart from lasting decisions and history. Large goals are
divided into smaller plans, while an automated retrieval tool works like a
librarian and finds the context needed for the task at hand. The documents
still make sense without that tool.

This working system is not part of FlashOS. It is simply how I keep a long and
complicated project understandable.

I spend much of my time writing code and documentation, but no project begins
from nothing. Calling FlashOS independent does not mean that every line or
underlying component is mine. FlashOS uses the Redox kernel and substantial
parts of the Redox ecosystem as its technical foundation.

My responsibility is to decide where FlashOS goes and how its pieces fit
together. I develop its ideas, design its architecture, write and review
changes, integrate the work it builds upon, and keep improving the result.

## The standards I set for the project

FlashOS is a hobby project. It makes no promise of support, deadlines, growth,
or a future shaped by someone else's priorities. At the same time, publishing
the project gives me a standard to meet. When I say that something works or
has been tested, I want that statement to be true. When I describe a future
goal, I want readers to know that it is still a goal.

I have no interest in attracting attention through exaggeration. The
documentation states limitations, separates shipped behavior from future work,
and records which tests support a claim. It also credits the work on which
FlashOS is built. FlashOS is an independent project based on Redox, not an
official Redox OS distribution. I want that relationship to be as clear as any
claim about a feature or test result.

## What success means to me

I did not start FlashOS to build a large user base. Anyone who wants to try it,
study it, or contribute is welcome, but I am not measuring the project by its
popularity. I hope to use FlashOS as my daily operating system one day. That is
a personal ambition, not a condition the project must meet before it has value.

To me, FlashOS succeeded on its first day. I wanted to learn and enjoy the
work, and it has given me both. There will always be something else to improve.
I do not expect to reach a point where I consider a complex system perfect.

Still, things need to be finished. For me, that happens when the original goal
has been reached and I am happy with the result. Waiting for complete
satisfaction would mean never finishing anything at all.

I want to remain ambitious without pretending that the work is further along
than it is. I want enough structure to finish what I begin without losing the
curiosity that made me begin it. That brings me back to the question behind
FlashOS: **How would I do it?**

---

[← Previous: Roadmap](roadmap.md) · [Documentation index](README.md) · [Next: Contributing →](../CONTRIBUTING.md)
