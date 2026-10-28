"""Charts of single simulator runs (Supra): kerb then straight, and a standing start; writes docs/img/sim-*.png.

    pip install lupa matplotlib && python sim/plot.py
"""
import sys
from lupa import luajit21
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

import pathlib
R = str(pathlib.Path(__file__).resolve().parent.parent).replace("\\", "/")
L = luajit21.LuaRuntime(unpack_returned_tuples=True)
L.execute("package.path = '%s/sim/?.lua;%s/extension/lua/joypad-assist/KeyDrive/?.lua;' .. package.path" % (R, R))
run = L.eval("""function(root, scn, car, kind, over)
  local runner = require('runner'); local controllers = require('controllers')
  local s = dofile(root .. '/sim/scenarios/' .. scn .. '.lua')
  local c = dofile(root .. '/sim/cars/' .. car .. '.lua')
  local opts = { car = c, rate = 'physics', seed = 1 }
  if kind == 'oracle' then opts.oracle = true
  elseif kind == 'old' then opts.controller = controllers.keydrive({}, { MODE = 1 })
  else
    local t = dofile(root .. '/extension/lua/joypad-assist/KeyDrive/core/tuned.lua')
    local tp = {}
    for k, v in pairs(t.traction) do tp[k] = v end
    if over then for k, v in pairs(over) do tp[k] = v end end
    opts.controller = controllers.keydrive(t.throttle, tp)
  end
  local tr = runner.run(s, opts)
  local T, G, N, V = {}, {}, {}, {}
  for i = 1, tr.n, 3 do T[#T + 1] = tr.t[i]; G[#G + 1] = tr.thr[i]; N[#N + 1] = tr.nd[i]; V[#V + 1] = tr.v[i] * 3.6 end
  return T, G, N, V
end""")

def get(scn, kind, over=None):
    lo = L.table_from(over) if over else None
    t, g, n, v = run(R, scn, "rwd_supra", kind, lo)
    conv = lambda x: [x[i] for i in range(1, len(x) + 1)]
    return conv(t), conv(g), conv(n), conv(v)

INK, INK2, GRID = "#0b0b0b", "#52514e", "#e4e3df"
BLUE, ORANGE, ORACLE = "#2a78d6", "#eb6834", "#8a8984"
plt.rcParams.update({"font.size": 10, "axes.edgecolor": GRID, "axes.labelcolor": INK2, "xtick.color": INK2,
                     "ytick.color": INK2, "axes.titlecolor": INK, "axes.titleweight": "bold", "axes.titlesize": 10.5,
                     "axes.titlelocation": "left"})

def figure(scn, series, title, out, shade=None, nd_max=4):
    fig, axes = plt.subplots(3, 1, figsize=(9, 8.2), sharex=True, facecolor="#fcfcfb")
    for ax in axes:
        ax.set_facecolor("#fcfcfb"); ax.grid(True, color=GRID, linewidth=0.8); ax.set_axisbelow(True)
        for sp in ("top", "right"): ax.spines[sp].set_visible(False)
        if shade: ax.axvspan(shade[0], shade[1], color="#eda100", alpha=0.18, linewidth=0)
    for label, kind, over, color, style in series:
        t, g, n, v = get(scn, kind, over)
        axes[0].plot(t, g, color=color, linestyle=style, linewidth=2, label=label)
        axes[1].plot(t, [min(x, nd_max) for x in n], color=color, linestyle=style, linewidth=2)
        axes[2].plot(t, v, color=color, linestyle=style, linewidth=2)
    axes[0].set_title("Plyn (0–1)"); axes[0].set_ylim(-0.03, 1.05)
    axes[1].set_title("Prokluz hnaných kol (1 = vrchol pneumatiky, oříznuto na %d)" % nd_max)
    axes[1].axhline(1.0, color=INK2, linewidth=1, linestyle=":"); axes[1].axhline(1.5, color="#d03b3b", linewidth=1, linestyle=":")
    axes[1].text(axes[1].get_xlim()[0], 1.55, " práh 1,5×", color="#d03b3b", fontsize=8.5, va="bottom")
    axes[2].set_title("Rychlost (km/h)"); axes[2].set_xlabel("čas (s)")
    axes[0].legend(loc="lower right", frameon=False, ncol=len(series))
    fig.suptitle(title, x=0.01, ha="left", fontsize=12.5, fontweight="bold", color=INK)
    if shade:
        axes[0].text((shade[0] + shade[1]) / 2, 1.02, "obrubník", ha="center", va="bottom", fontsize=8.5, color=INK2)
    fig.tight_layout(rect=(0, 0, 1, 0.96))
    fig.savefig(out, dpi=130, facecolor=fig.get_facecolor())
    print(out)

figure("kerb_straight", [
    ("v0.10.0 (před opravou)", "new", {"FORGET_RATE": 0}, ORANGE, "-"),
    ("v0.10.1 (s opravou)", "new", None, BLUE, "-"),
    ("ideální noha (orákulum)", "oracle", None, ORACLE, "--")],
    "Simulátor: Supra, 3. převod, plný plyn, obrubník a pak rovina", R + "/docs/img/sim-kerb.png", shade=(1.5, 1.7))
figure("standing_start", [
    ("v0.9.3", "old", None, ORANGE, "-"),
    ("v0.10.1", "new", None, BLUE, "-"),
    ("ideální noha (orákulum)", "oracle", None, ORACLE, "--")],
    "Simulátor: Supra, rozjezd z místa na plný plyn", R + "/docs/img/sim-launch.png", nd_max=6)
