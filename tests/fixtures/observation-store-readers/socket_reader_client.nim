## FIXTURE, NOT SHIPPED CODE. The same job done correctly: the client asks
## ``runquotad`` over the socket and never names a database.
##
## ``t_observation_store_reader_boundary`` scans this file and requires it
## NOT to be flagged. Without it the scanner could pass by rejecting every
## file it is shown, which would make the gate above worthless in the other
## direction.

import runquota_client
import runquota_protocol

proc slowestExecutions*(client: var RunQuotaClient;
                        statsKey: string): StatsResponseMessage =
  client.queryStats(statsSubjectExecutions, statsKey)
