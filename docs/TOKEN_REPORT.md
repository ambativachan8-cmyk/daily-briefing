# Token usage report

Generated 2026-11-05T11:34:24Z from `runs.jsonl` (160 run attempts).
Counts are reported by the runtimes themselves (Hermes `--usage-file`, OpenClaw
`--json` agent meta). **Actual cost: $0** — every key is free tier. The "list-price
estimate" column is Hermes' own estimate of what the same tokens would cost on a paid
plan; OpenClaw reports `costUsd: 0` for these models. Model calls are exact for Hermes
(`api_calls`); for OpenClaw the column shows assistant turns, a lower bound.

## By agent and model

| Agent | Framework | Model | Runs | Model calls | Input tokens | Output tokens | Cache-read | Total | List-price estimate (USD) |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| backend | openclaw | gemini-3-flash-preview | 14 | 31 | 253969 | 11636 | 1031211 | 1296816 | 0 |
| backend | openclaw | gemini-3.1-flash-lite | 9 | 89 | 610672 | 18534 | 1016145 | 1645351 | 0 |
| backend | openclaw | gemini-3.5-flash | 6 | 26 | 177806 | 8376 | 378086 | 564268 | 0 |
| backend | openclaw | gemini-3.5-flash-lite | 25 | 142 | 565176 | 64665 | 5170473 | 5800314 | 0 |
| backend | openclaw | gemini-3.6-flash | 7 | 2 | 56293 | 251 | 0 | 56544 | 0 |
| backend | openclaw | nvidia/nemotron-3-ultra-550b-a55b:free | 4 | 122 | 412904 | 40309 | 5010912 | 5464125 | 0 |
| manager | hermes | gemini-3-flash-preview | 1 | 7 | 54700 | 3606 | 32331 | 58637 | 0.0236 |
| manager | hermes | gemini-3.1-flash-lite | 2 | 23 | 290077 | 1035 | 176691 | 291901 | 0.0365 |
| manager | hermes | gemini-3.5-flash-lite | 5 | 64 | 561952 | 7967 | 280714 | 571841 | 0.1845 |
| manager | hermes | gemini-3.6-flash | 1 | 16 | 191529 | 5532 | 99829 | 197426 | 0.145 |
| reviewer | hermes | gemini-3-flash-preview | 2 | 23 | 351432 | 12400 | 219672 | 364526 | 0.235 |
| reviewer | hermes | gemini-3.1-flash-lite | 8 | 105 | 1661204 | 10561 | 1032937 | 1672245 | 0.2437 |
| reviewer | hermes | gemini-3.5-flash-lite | 12 | 94 | 1278856 | 14091 | 848264 | 1293455 | 0.2218 |
| reviewer | hermes | nvidia/nemotron-3-ultra-550b-a55b:free | 5 | 77 | 1738134 | 22791 | 1181949 | 1526720 | 0.0587 |
| tester | openclaw | gemini-3-flash-preview | 5 | 19 | 86060 | 3445 | 162344 | 251849 | 0 |
| tester | openclaw | gemini-3.1-flash-lite | 1 | 4 | 20105 | 801 | 48725 | 69631 | 0 |
| tester | openclaw | gemini-3.5-flash-lite | 19 | 203 | 1146551 | 51188 | 2322319 | 3520058 | 0 |
| tester | openclaw | gemini-3.6-flash | 3 | 9 | 52035 | 2208 | 37043 | 91286 | 0 |
| ui | openclaw | gemini-3.1-flash-lite | 25 | 276 | 1549356 | 35932 | 3430179 | 5015467 | 0 |
| ui | openclaw | gemini-3.5-flash-lite | 4 | 4 | 30131 | 270 | 24288 | 54689 | 0 |
| ui | openclaw | nvidia/nemotron-3-ultra-550b-a55b:free | 2 | 0 | 0 | 0 | 0 | 0 | 0 |

## By agent

| Agent | Runs | Total tokens | Failed attempts (quota/provider) |
|---|---:|---:|---:|
| backend | 65 | 14827418 | 54 |
| manager | 9 | 1119805 | 0 |
| reviewer | 27 | 4856946 | 3 |
| tester | 28 | 3932824 | 12 |
| ui | 31 | 5070156 | 23 |

## By phase

Each attempt counts once. An agent's first successful run on a ticket goes to its phase
(manager: planning; backend, ui: coding; reviewer, tester: review/test). Every other attempt
(a failed attempt, or a repeat run on the same ticket, such as a re-review or rework after a
send-back) counts as a retry. Fresh tokens exclude cache reads, which the two runtimes report
differently: OpenClaw's input excludes them and Hermes' input includes them.

| Phase | Attempts | Fresh tokens | Cache-read | Total reported |
|---|---:|---:|---:|---:|
| coding | 5 | 359202 | 2048722 | 2407924 |
| planning | 4 | 195949 | 165669 | 363079 |
| retries | 141 | 6000658 | 17967911 | 23736583 |
| review/test | 10 | 976344 | 2321810 | 3299563 |

## Every run

| Time (UTC) | Agent | Ticket | Model | Status | Total tokens |
|---|---|---|---|---|---:|
| 20261102T212136Z | manager | plan | gemini-3-flash-preview | ok | 58637 |
| 20261102T212327Z | backend | #1 | google/gemini-3.6-flash | error | 0 |
| 20261102T212332Z | backend | #1 | gemini-3-flash-preview | error | 17721 |
| 20261102T212444Z | backend | #1 | google/gemini-3-flash-preview | error | 0 |
| 20261102T212447Z | backend | #1 | nvidia/nemotron-3-ultra-550b-a55b:free | ok | 1019786 |
| 20261102T212817Z | reviewer | #1 | gemini-3.5-flash-lite | ok | 178880 |
| 20261103T080054Z | reviewer | #1 | gemini-3-flash-preview | ok | 150656 |
| 20261103T081054Z | tester | #1 | google/gemini-3.6-flash | error | 91286 |
| 20261103T081250Z | tester | #1 | google/gemini-3.6-flash | error | 0 |
| 20261103T081255Z | tester | #1 | google/gemini-3-flash-preview | ok | 192877 |
| 20261103T091425Z | manager | #2 | gemini-3.5-flash-lite | ok | 62044 |
| 20261103T092059Z | backend | #2 | google/gemini-3.5-flash | error | 0 |
| 20261103T092106Z | backend | #2 | google/gemini-3.6-flash | error | 0 |
| 20261103T092108Z | backend | #2 | google/gemini-3-flash-preview | error | 8951 |
| 20261103T092219Z | backend | #2 | google/gemini-3-flash-preview | error | 0 |
| 20261103T092222Z | backend | #2 | openrouter/nvidia/nemotron-3-ultra-550b-a55b:free | ok | 962911 |
| 20261103T093051Z | reviewer | #2 | nvidia/nemotron-3-ultra-550b-a55b:free | ok | 386587 |
| 20261103T094054Z | tester | #2 | google/gemini-3.6-flash | error | 0 |
| 20261103T094058Z | tester | #2 | google/gemini-3-flash-preview | error | 18498 |
| 20261103T094236Z | tester | #2 | google/gemini-3-flash-preview | error | 0 |
| 20261103T094240Z | tester | #2 | google/gemini-3.5-flash-lite | ok | 327033 |
| 20261104T210423Z | reviewer | #2 | gemini-3-flash-preview | ok | 213870 |
| 20261104T210645Z | manager | #2 | gemini-3.6-flash | ok | 197426 |
| 20261104T211059Z | backend | #2 | google/gemini-3.5-flash | error | 110023 |
| 20261104T211221Z | backend | #2 | google/gemini-3.5-flash | error | 0 |
| 20261104T211225Z | backend | #2 | google/gemini-3.6-flash | error | 56544 |
| 20261104T211342Z | backend | #2 | google/gemini-3.6-flash | error | 0 |
| 20261104T211345Z | backend | #2 | google/gemini-3-flash-preview | error | 377867 |
| 20261104T211726Z | backend | #2 | google/gemini-3-flash-preview | error | 0 |
| 20261104T211814Z | backend | #2 | openrouter/nvidia/nemotron-3-ultra-550b-a55b:free | ok | 3481428 |
| 20261104T212711Z | backend | #2 | google/gemini-3.5-flash | error | 0 |
| 20261104T212727Z | backend | #2 | google/gemini-3.6-flash | error | 0 |
| 20261104T212922Z | backend | #2 | google/gemini-3-flash-preview | error | 0 |
| 20261104T212925Z | backend | #2 | openrouter/nvidia/nemotron-3-ultra-550b-a55b:free | error | 0 |
| 20261104T213056Z | reviewer | #2 | nvidia/nemotron-3-ultra-550b-a55b:free | exit 2 | 0 |
| 20261104T222335Z | backend | #2 | google/gemini-3-flash-preview | error | 0 |
| 20261104T222342Z | backend | #2 | google/gemini-3.5-flash-lite | error | 0 |
| 20261104T222839Z | backend | #2 | google/gemini-3-flash-preview | error | 0 |
| 20261104T222951Z | backend | #2 | google/gemini-3-flash-preview | error | 0 |
| 20261104T222955Z | backend | #2 | google/gemini-3.5-flash-lite | error | 279124 |
| 20261104T223150Z | backend | #2 | google/gemini-3.5-flash-lite | error | 38973 |
| 20261104T223329Z | backend | #2 | google/gemini-3.1-flash-lite | error | 0 |
| 20261104T223815Z | backend | #2 | google/gemini-3.1-flash-lite | error | 51858 |
| 20261104T223940Z | backend | #2 | google/gemini-3.5-flash-lite | error | 249235 |
| 20261104T224105Z | backend | #2 | google/gemini-3.5-flash-lite | error | 212971 |
| 20261104T224232Z | backend | #2 | google/gemini-3.5-flash-lite | error | 248900 |
| 20261104T224406Z | backend | #2 | google/gemini-3.5-flash-lite | error | 183185 |
| 20261104T224531Z | backend | #2 | google/gemini-3.5-flash-lite | error | 190434 |
| 20261104T224646Z | backend | #2 | google/gemini-3.5-flash-lite | error | 192738 |
| 20261104T224804Z | backend | #2 | google/gemini-3.5-flash-lite | error | 194511 |
| 20261104T224926Z | backend | #2 | google/gemini-3.5-flash-lite | ok | 97886 |
| 20261104T225037Z | reviewer | #2 | gemini-3.1-flash-lite | ok | 378840 |
| 20261104T225242Z | backend | #2 | google/gemini-3.5-flash-lite | error | 350269 |
| 20261104T225438Z | backend | #2 | google/gemini-3.5-flash-lite | error | 237200 |
| 20261104T225600Z | backend | #2 | google/gemini-3.5-flash-lite | error | 265653 |
| 20261104T225728Z | backend | #2 | google/gemini-3.5-flash-lite | error | 262062 |
| 20261104T225856Z | backend | #2 | google/gemini-3.5-flash-lite | error | 312447 |
| 20261104T230030Z | backend | #2 | google/gemini-3.5-flash-lite | error | 269911 |
| 20261104T230152Z | backend | #2 | google/gemini-3.5-flash-lite | error | 356114 |
| 20261104T230316Z | backend | #2 | google/gemini-3.5-flash-lite | error | 193922 |
| 20261104T230430Z | backend | #2 | google/gemini-3.5-flash-lite | error | 195949 |
| 20261104T230553Z | backend | #2 | google/gemini-3.5-flash-lite | ok | 197935 |
| 20261104T230631Z | backend | #2 | google/gemini-3.5-flash-lite | error | 238696 |
| 20261104T230817Z | backend | #2 | google/gemini-3.5-flash-lite | error | 384524 |
| 20261104T231000Z | backend | #2 | google/gemini-3.5-flash-lite | error | 205998 |
| 20261104T231118Z | backend | #2 | google/gemini-3.5-flash-lite | ok | 441677 |
| 20261104T231433Z | reviewer | #2 | gemini-3.1-flash-lite | ok | 199471 |
| 20261104T232051Z | reviewer | #2 | gemini-3.5-flash-lite | ok | 149995 |
| 20261104T232600Z | tester | #2 | google/gemini-3.5-flash-lite | error | 715841 |
| 20261104T233100Z | tester | #2 | google/gemini-3.5-flash-lite | error | 252615 |
| 20261104T233249Z | tester | #2 | google/gemini-3.5-flash-lite | ok | 112854 |
| 20261105T075056Z | manager | #3 | gemini-3.5-flash-lite | ok | 172558 |
| 20261105T080055Z | backend | #5 | google/gemini-3.5-flash | error | 454245 |
| 20261105T080629Z | backend | #5 | google/gemini-3.5-flash | error | 0 |
| 20261105T080632Z | backend | #5 | google/gemini-3.6-flash | error | 0 |
| 20261105T080740Z | backend | #5 | google/gemini-3.6-flash | error | 0 |
| 20261105T080743Z | backend | #5 | google/gemini-3-flash-preview | error | 219709 |
| 20261105T080915Z | backend | #5 | google/gemini-3-flash-preview | error | 245123 |
| 20261105T081043Z | backend | #5 | google/gemini-3-flash-preview | error | 283174 |
| 20261105T081215Z | backend | #5 | google/gemini-3-flash-preview | ok | 144271 |
| 20261105T081241Z | reviewer | #5 | gemini-3.1-flash-lite | ok | 300890 |
| 20261105T082055Z | tester | #5 | google/gemini-3-flash-preview | error | 40474 |
| 20261105T082218Z | tester | #5 | google/gemini-3-flash-preview | error | 0 |
| 20261105T082220Z | tester | #5 | google/gemini-3.5-flash-lite | ok | 315425 |
| 20261105T082639Z | reviewer | #5 | gemini-3.5-flash-lite | ok | 180745 |
| 20261105T083046Z | tester | #5 | google/gemini-3.5-flash-lite | ok | 22569 |
| 20261105T083957Z | tester | #5 | google/gemini-3.5-flash-lite | ok | 94498 |
| 20261105T084044Z | reviewer | #5 | nvidia/nemotron-3-ultra-550b-a55b:free | ok | 348734 |
| 20261105T084342Z | tester | #5 | google/gemini-3.5-flash-lite | ok | 77083 |
| 20261105T084429Z | backend | #11 | google/gemini-3.1-flash-lite | error | 242949 |
| 20261105T084613Z | backend | #11 | google/gemini-3.1-flash-lite | ok | 157562 |
| 20261105T084658Z | reviewer | #11 | nvidia/nemotron-3-ultra-550b-a55b:free | ok | 790838 |
| 20261105T085159Z | ui | #3 | google/gemini-3.1-flash-lite | error | 357517 |
| 20261105T085430Z | ui | #3 | google/gemini-3.1-flash-lite | error | 245065 |
| 20261105T085612Z | ui | #3 | google/gemini-3.1-flash-lite | ok | 123394 |
| 20261105T085651Z | reviewer | #3 | nvidia/nemotron-3-ultra-550b-a55b:free | exit 2 | 561 |
| 20261105T091501Z | reviewer | #3 | gemini-3.1-flash-lite | ok | 295905 |
| 20261105T091718Z | tester | #5 | google/gemini-3.5-flash-lite | ok | 123246 |
| 20261105T091828Z | ui | #3 | google/gemini-3.1-flash-lite | error | 395150 |
| 20261105T092049Z | ui | #3 | google/gemini-3.1-flash-lite | ok | 146007 |
| 20261105T092128Z | reviewer | #3 | gemini-3.1-flash-lite | ok | 245891 |
| 20261105T092318Z | reviewer | #3 | gemini-3.1-flash-lite | ok | 206933 |
| 20261105T092510Z | tester | #3 | google/gemini-3.5-flash-lite | ok | 464150 |
| 20261105T092848Z | manager | #3 | gemini-3.5-flash-lite | ok | 188369 |
| 20261105T093016Z | ui | #3 | google/gemini-3.1-flash-lite | ok | 238824 |
| 20261105T093257Z | reviewer | #3 | gemini-3.5-flash-lite | ok | 94166 |
| 20261105T093445Z | tester | #3 | google/gemini-3.5-flash-lite | ok | 230546 |
| 20261105T093806Z | reviewer | #3 | gemini-3.5-flash-lite | ok | 58792 |
| 20261105T093920Z | tester | #3 | google/gemini-3.5-flash-lite | ok | 218291 |
| 20261105T094256Z | manager | #11 | gemini-3.5-flash-lite | ok | 69840 |
| 20261105T094500Z | backend | #11 | google/gemini-3.1-flash-lite | error | 226611 |
| 20261105T094705Z | backend | #11 | google/gemini-3.1-flash-lite | ok | 215765 |
| 20261105T094758Z | reviewer | #11 | gemini-3.5-flash-lite | ok | 65244 |
| 20261105T094944Z | tester | #11 | google/gemini-3.5-flash-lite | error | 0 |
| 20261105T095313Z | tester | #11 | google/gemini-3.5-flash-lite | ok | 46978 |
| 20261105T095339Z | reviewer | #11 | gemini-3.5-flash-lite | ok | 195181 |
| 20261105T095519Z | tester | #11 | google/gemini-3.5-flash-lite | ok | 217469 |
| 20261105T095732Z | ui | #3 | google/gemini-3.1-flash-lite | error | 165895 |
| 20261105T095904Z | ui | #3 | google/gemini-3.1-flash-lite | error | 247362 |
| 20261105T100037Z | ui | #3 | google/gemini-3.1-flash-lite | error | 249198 |
| 20261105T100200Z | ui | #3 | google/gemini-3.1-flash-lite | error | 262399 |
| 20261105T100501Z | ui | #3 | google/gemini-3.1-flash-lite | ok | 127213 |
| 20261105T100521Z | ui | #3 | google/gemini-3.1-flash-lite | error | 106750 |
| 20261105T100659Z | ui | #3 | google/gemini-3.1-flash-lite | error | 251723 |
| 20261105T100839Z | ui | #3 | google/gemini-3.1-flash-lite | ok | 404031 |
| 20261105T100940Z | reviewer | #3 | gemini-3.5-flash-lite | ok | 112645 |
| 20261105T101131Z | backend | #11 | google/gemini-3.1-flash-lite | ok | 319928 |
| 20261105T101257Z | backend | #11 | google/gemini-3.1-flash-lite | error | 245587 |
| 20261105T101527Z | backend | #11 | google/gemini-3.1-flash-lite | ok | 185091 |
| 20261105T101557Z | reviewer | #11 | gemini-3.5-flash-lite | ok | 42102 |
| 20261105T101706Z | tester | #11 | google/gemini-3.5-flash-lite | ok | 88247 |
| 20261105T101824Z | reviewer | #11 | gemini-3.1-flash-lite | exit 2 | 0 |
| 20261105T102052Z | reviewer | #11 | gemini-3.1-flash-lite | ok | 44315 |
| 20261105T102431Z | tester | #11 | google/gemini-3.5-flash-lite | ok | 196336 |
| 20261105T102929Z | manager | #3 | gemini-3.1-flash-lite | ok | 203180 |
| 20261105T103041Z | ui | #3 | google/gemini-3.1-flash-lite | error | 306391 |
| 20261105T103259Z | ui | #3 | google/gemini-3.1-flash-lite | ok | 133715 |
| 20261105T103331Z | reviewer | #3 | gemini-3.5-flash-lite | ok | 82236 |
| 20261105T103605Z | reviewer | #11 | gemini-3.5-flash-lite | ok | 69814 |
| 20261105T103830Z | manager | #3 | gemini-3.5-flash-lite | ok | 79030 |
| 20261105T104103Z | ui | #3 | google/gemini-3.1-flash-lite | error | 206908 |
| 20261105T104244Z | ui | #3 | google/gemini-3.1-flash-lite | error | 49344 |
| 20261105T104403Z | ui | #3 | google/gemini-3.1-flash-lite | ok | 53687 |
| 20261105T104700Z | ui | #3 | google/gemini-3.1-flash-lite | error | 245259 |
| 20261105T104843Z | ui | #3 | google/gemini-3.1-flash-lite | error | 108761 |
| 20261105T105002Z | ui | #3 | google/gemini-3.1-flash-lite | error | 250718 |
| 20261105T105201Z | ui | #3 | google/gemini-3.1-flash-lite | ok | 102872 |
| 20261105T105234Z | reviewer | #3 | gemini-3.5-flash-lite | ok | 63655 |
| 20261105T105502Z | tester | #3 | google/gemini-3.5-flash-lite | error | 0 |
| 20261105T105705Z | tester | #3 | google/gemini-3.5-flash-lite | error | 16877 |
| 20261105T105712Z | tester | #3 | google/gemini-3.1-flash-lite | ok | 69631 |
| 20261105T105740Z | manager | #3 | gemini-3.1-flash-lite | ok | 88721 |
| 20261105T105920Z | ui | #3 | google/gemini-3.1-flash-lite | error | 194882 |
| 20261105T110055Z | ui | #3 | google/gemini-3.1-flash-lite | error | 42402 |
| 20261105T110102Z | ui | #3 | openrouter/nvidia/nemotron-3-ultra-550b-a55b:free | error | 0 |
| 20261105T110209Z | ui | #3 | openrouter/nvidia/nemotron-3-ultra-550b-a55b:free | error | 0 |
| 20261105T112708Z | ui | #3 | google/gemini-3.5-flash-lite | error | 0 |
| 20261105T112856Z | ui | #3 | google/gemini-3.5-flash-lite | error | 25420 |
| 20261105T113025Z | ui | #3 | google/gemini-3.5-flash-lite | error | 29269 |
| 20261105T113138Z | ui | #3 | google/gemini-3.5-flash-lite | error | 0 |
