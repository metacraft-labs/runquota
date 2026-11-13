# runquota_admission

The order in which `runquotad` tries queued lease requests: dominant-resource
fairness between owners, then within each owner's share the starvation bound
and the session groups by priority, prompt-cache deadline and arrival. Pure:
no daemon state and no I/O, so the order is testable on its own.
