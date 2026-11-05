# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Prints every dependency edge that is not strictly ordered by wave. See README.adoc.
FNR==NR { id=$1; w=$2; lane=$3; seq=$4;
  base=id; if (id!="L-12b") sub(/(a|b|c|s)$/,"",base);
  if (!(base in mn) || w<mn[base]) mn[base]=w;
  if (!(base in mx) || w>mx[base]) mx[base]=w;
  W[id]=w; L[id]=lane; S[id]=seq; parts[base]=parts[base] " " id; next }
{ f=$1; t=$2;
  if (mx[f] < mn[t]) status="OK"; else if (mx[f]==mn[t]) status="SAMEWAVE"; else status="VIOLATION";
  if (status!="OK") printf "%s %s->%s from[%s..%s]%s to[%s..%s]%s\n", status,f,t,mn[f],mx[f],parts[f],mn[t],mx[t],parts[t] }
