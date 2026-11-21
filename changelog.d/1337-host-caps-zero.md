* `worker-placement.py` treats `host_caps` 0 as no seats: `pick` never returns that host, `check-host` refuses it, and `seats` leaves it out.
