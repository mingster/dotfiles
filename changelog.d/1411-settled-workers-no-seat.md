Worker placement no longer counts a settled, exited worker (succeeded, failed, cancelled) toward the host cap, released or not. Unpushed work still holds a seat.
A recent start now counts as one pending seat instead of the host total at start, and it stops counting (seat and 4 GB of memory) once the inventory lists its dispatch, live or settled.
