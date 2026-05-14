# ASCENT PPA Ablation Comparison - Python 2 compatible, ASCII only
# Run: python ppa_compare.py
import re, os

def get_power(f):
    if not os.path.exists(f):
        return None
    for line in open(f):
        if "ascent_top" in line and re.search(r'\d+\.\d+', line):
            nums = re.findall(r'[\d]+\.[\d]+', line)
            if nums:
                return float(nums[-1]) / 1e6
    return None

def get_cells(f):
    if not os.path.exists(f):
        return None
    for line in open(f):
        if "ascent_top" in line:
            m = re.search(r'ascent_top\s+(\d+)', line)
            if m:
                return int(m.group(1))
    return None

PA = get_power("reports/power_A_exact_dense.rpt")
PB = get_power("reports/power_B_loa_dense.rpt")
PC = get_power("reports/power_report.rpt")
CA = get_cells("reports/area_A_exact_dense.rpt")
CB = get_cells("reports/area_B_loa_dense.rpt")
CC = get_cells("reports/area_report.rpt")

print "=" * 62
print "   ASCENT PPA ABLATION SUMMARY"
print "=" * 62
print "%-38s %8s %10s" % ("Stage", "Cells", "Power")
print "-" * 62
print "%-38s %8s %10s" % (
    "A  Exact mult + Dense (baseline)",
    str(CA) if CA else "N/A",
    ("%.2f mW" % PA) if PA else "N/A"
)
print "%-38s %8s %10s" % (
    "B  LOA mult + Dense",
    str(CB) if CB else "N/A",
    ("%.2f mW" % PB) if PB else "N/A"
)
print "%-38s %8s %10s" % (
    "C  LOA mult + 50pct Sparse (ASCENT)",
    str(CC) if CC else "N/A",
    ("%.2f mW" % PC) if PC else "N/A"
)
print "=" * 62

if PA and PB and PC:
    print "LOA approx computing saves:  %.1f%%  (%.2f -> %.2f mW)" % ((1-PB/PA)*100, PA, PB)
    print "Sparse row gating saves:     %.1f%%  (%.2f -> %.2f mW)" % ((1-PC/PB)*100, PB, PC)
    print "Total ASCENT saving:         %.1f%%  (%.2f -> %.2f mW)" % ((1-PC/PA)*100, PA, PC)
else:
    print "Some reports missing. Status:"
    for name, f in [
        ("A power", "reports/power_A_exact_dense.rpt"),
        ("B power", "reports/power_B_loa_dense.rpt"),
        ("C power", "reports/power_report.rpt")
    ]:
        print "  %s: %s" % (name, "EXISTS" if os.path.exists(f) else "MISSING")
