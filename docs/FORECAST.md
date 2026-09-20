# The forecast, and why the menu bar isn't enough

Claude Code will tell you a number. `/usage` gives you the same percentages Cashew reads, and you
can look at them whenever you think to.

The gap isn't the number, it's the rate. **40% an hour into a five-hour window and 40% four hours in
are the same reading and opposite situations**, and nothing that samples once can tell them apart.
The first is a morning that ends fine. The second is a morning that ends at 3pm.

So Cashew keeps a short history of what each limit has read and works out how fast you're actually
moving. When that rate would reach the cap before the window resets, one line appears under the
limit:

```
On pace to hit the limit ~Thu 14:00
```

and, for a weekly limit, the percentage in the menu bar turns yellow even if it's nowhere near the
usual threshold — because a weekly limit you'll hit on Thursday is worth knowing about at 30%.

## Silence is the normal state

The rest of the time it says nothing at all. There is deliberately no "you're fine" message: a line
that reassures you every ordinary day is a line you stop reading, and then it goes unread on the day
it matters. The forecast appearing is the signal.

## Two honest limits

It's a straight-line projection over a trailing window — 90 minutes for a session limit, a day for a
weekly one — so it assumes the next hour looks like the last, which it won't if you stop for lunch
or start a big refactor.

And it needs a few samples before it will say anything, so a freshly installed Cashew stays quiet
for a while. When it can't tell, it says nothing rather than guessing.

That second limit is stricter than it sounds, and deliberately so. The percentages the API returns
are whole integers, so one point is the smallest change it can express — which means any reading
carries about half a point of rounding. Fitting a line to that too eagerly produces confident
nonsense. The first real run of an earlier version took five weekly samples over 22 minutes, saw one
point of movement, and announced "on pace to hit the limit ~Sat 1:44 AM" for a limit sitting at 2%.

So the forecast now requires the samples to span at least a quarter of their trailing window **and**
to have moved more than one point. Sample *count* is not observation *time*, and both conditions
have to hold.
