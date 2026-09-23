#!/bin/bash
# H8: mutation check of c4b-cd-check-dns.sh. Each mutant changes exactly ONE
# expected fact (the diff is printed and must be 1 line), runs, and must exit
# non-zero with a FAIL on the mutated guard. M1-M3, M5 skip the destructive
# C6' (RUN_C6=0); M4 keeps C6' but never deletes the peer.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
S=c4b-cd-check-dns.sh
LOG="${HOME}/mokka-hetero/logs/h8-c4b-mutants.log"
exec > >(tee "${LOG}") 2>&1
echo "start $(date -u +%FT%TZ) subject sha256 $(sha256sum "${S}" | cut -c1-16)"
declare -a NAME FROM TO C6
NAME+=(M1-ready-3to4);        FROM+=('[[ "${r}" -eq 3 && "${u}" -eq 15');  TO+=('[[ "${r}" -eq 4 && "${u}" -eq 15');  C6+=(0)
NAME+=(M2-unavail-15to14);    FROM+=('"${u}" -eq 15 && "${t}"');           TO+=('"${u}" -eq 14 && "${t}"');           C6+=(0)
NAME+=(M3-clique-32766to0);   FROM+=('0001.32766"');                       TO+=('0001.0"');                           C6+=(0)
NAME+=(M4-c6-no-delete);      FROM+=('kubectl -n "${DRV}" delete "${d9}" --wait=false'); TO+=('true # M4: peer NOT deleted'); C6+=(1)
NAME+=(M5-pairwise-CONNECTED); FROM+=('all(.=="CONNECTED")');              TO+=('all(.=="NEVER_CONNECTED")');         C6+=(0)
survived=0
for i in "${!NAME[@]}"; do
  m="mut-${NAME[$i]}.sh"
  python3 - "${S}" "${m}" "${FROM[$i]}" "${TO[$i]}" <<'EOF'
import sys
src, dst, a, b = sys.argv[1:]
s = open(src).read()
n = s.count(a)
assert n == 1, f"pattern count {n} != 1: {a}"
open(dst, "w").write(s.replace(a, b))
EOF
  prc=$?
  echo "=================== ${NAME[$i]} (RUN_C6=${C6[$i]}) apply rc=${prc}"
  [[ ${prc} -eq 0 ]] || { echo "MUTANT NOT APPLIED"; survived=1; continue; }
  d="$(diff "${S}" "${m}")"; echo "${d}"
  [[ "$(grep -c '^>' <<< "${d}")" -eq 1 && "$(grep -c '^<' <<< "${d}")" -eq 1 ]] || { echo "MUTANT DIFF NOT 1 LINE"; survived=1; continue; }
  RUN_C6="${C6[$i]}" bash "${m}" > "${HOME}/mokka-hetero/logs/h8-${NAME[$i]}.out" 2>&1
  rc=$?
  cp "${HOME}/mokka-hetero/logs/h8-c4b-cd-check-dns.log" "${HOME}/mokka-hetero/logs/h8-${NAME[$i]}.log"
  grep -E '^FAIL|^DONE' "${HOME}/mokka-hetero/logs/h8-${NAME[$i]}.log"
  if [[ ${rc} -ne 0 ]]; then echo "KILLED ${NAME[$i]} rc=${rc}"; else echo "SURVIVED ${NAME[$i]} rc=${rc}"; survived=1; fi
  rm -f "${m}"
done
echo "DONE survived=${survived} $(date -u +%FT%TZ)"
exit "${survived}"
