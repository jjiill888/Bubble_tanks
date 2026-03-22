#!/usr/bin/env python3
"""
Boss Genetic Algorithm Evolution
=================================
进化出有趣的 Boss 形态，输出 boss_genomes.json 供游戏加载。

用法:
    python3 ga_evolve.py              # 进化并保存
    python3 ga_evolve.py --preview    # 进化后用 matplotlib 预览 top-8 形态
"""

import random
import math
import json
import copy
import sys
from dataclasses import dataclass, field
from typing import List, Tuple

# ─── 参数 ────────────────────────────────────────────────────────────────────
CORE_RADIUS_MIN  = 30.0
CORE_RADIUS_MAX  = 52.0
SM_R_MIN         = 11.0
SM_R_MAX         = 22.0
MIN_BUBBLES      = 8        # 包含核心在内
MAX_BUBBLES      = 20

POPULATION_SIZE  = 100
GENERATIONS      = 300
ELITE_FRACTION   = 0.10
TOURNAMENT_SIZE  = 6
CROSSOVER_RATE   = 0.75
MUTATION_RATE    = 0.15

KEEP_TOP_N       = 20       # 保存到 JSON 的数量
OUTPUT_FILE      = "boss_genomes.json"


# ─── 数据类 ──────────────────────────────────────────────────────────────────
@dataclass
class BubbleGene:
    parent_idx: int   # 挂在哪个泡泡上（0 = 核心）
    angle:      float # 相对父泡的角度（弧度）
    radius:     float # 自身半径
    hp:         int   # 血量

@dataclass
class BossGenome:
    core_radius: float
    satellites:  List[BubbleGene]  # 不含核心
    initial_heading: float = 0.0
    turn_rate: float = 2.0
    preferred_range: float = 180.0
    orbit_weight: float = 0.5
    orbit_dir: int = 1
    aim_lead: float = 0.1

    def clone(self):
        return copy.deepcopy(self)

    def to_dict(self) -> dict:
        return {
            "core_radius": round(self.core_radius, 2),
            "initial_heading": round(self.initial_heading % (2 * math.pi), 4),
            "turn_rate": round(self.turn_rate, 3),
            "preferred_range": round(self.preferred_range, 2),
            "orbit_weight": round(self.orbit_weight, 3),
            "orbit_dir": int(self.orbit_dir),
            "aim_lead": round(self.aim_lead, 3),
            "satellites": [
                {
                    "parent_idx": b.parent_idx,
                    "angle":      round(b.angle % (2 * math.pi), 4),
                    "radius":     round(b.radius, 2),
                    "hp":         b.hp,
                }
                for b in self.satellites
            ],
        }

    @staticmethod
    def from_dict(d: dict) -> "BossGenome":
        return BossGenome(
            core_radius=d["core_radius"],
            satellites=[BubbleGene(**b) for b in d["satellites"]],
            initial_heading=d.get("initial_heading", random.uniform(0, math.tau)),
            turn_rate=d.get("turn_rate", 2.0),
            preferred_range=d.get("preferred_range", 180.0),
            orbit_weight=d.get("orbit_weight", 0.5),
            orbit_dir=d.get("orbit_dir", 1),
            aim_lead=d.get("aim_lead", 0.1),
        )


def random_behavior() -> dict:
    return {
        "initial_heading": random.uniform(0, math.tau),
        "turn_rate": random.uniform(0.9, 4.0),
        "preferred_range": random.uniform(100.0, 290.0),
        "orbit_weight": random.uniform(0.15, 1.0),
        "orbit_dir": random.choice([-1, 1]),
        "aim_lead": random.uniform(0.0, 0.55),
    }


# ─── 基因组解码（基因 → 实际位置列表）────────────────────────────────────────
def decode(genome: BossGenome) -> List[Tuple[float, float, float]]:
    """返回 [(x, y, r), ...] 实际放置成功的泡泡，核心在 index 0。"""
    placed: List[Tuple[float, float, float]] = [(0.0, 0.0, genome.core_radius)]

    for gene in genome.satellites:
        pidx = min(gene.parent_idx, len(placed) - 1)
        px, py, pr = placed[pidx]
        dist = pr + gene.radius
        nx = px + dist * math.cos(gene.angle)
        ny = py + dist * math.sin(gene.angle)

        # 碰撞检测
        ok = all(
            math.hypot(nx - ex, ny - ey) >= gene.radius + er - 1.5
            for ex, ey, er in placed
        )
        if ok:
            placed.append((nx, ny, gene.radius))

    return placed


# ─── 适应度函数 ───────────────────────────────────────────────────────────────
def _convex_hull(pts: List[Tuple[float, float]]) -> List[Tuple[float, float]]:
    pts = sorted(set(pts))
    if len(pts) < 3:
        return pts
    def cross(O, A, B):
        return (A[0]-O[0])*(B[1]-O[1]) - (A[1]-O[1])*(B[0]-O[0])
    lower, upper = [], []
    for p in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    for p in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]

def _polygon_area(pts) -> float:
    n = len(pts)
    if n < 3: return 0.0
    s = sum(pts[i][0]*pts[(i+1)%n][1] - pts[(i+1)%n][0]*pts[i][1] for i in range(n))
    return abs(s) / 2.0

def fitness(genome: BossGenome) -> float:
    placed = decode(genome)
    n = len(placed)
    if n < MIN_BUBBLES:
        return 0.0

    cx, cy, cr = placed[0]

    # ── 1. 数量得分（越多越好，边际递减）──────────────────────────────────
    count_score = min(1.0, (n - MIN_BUBBLES) / (MAX_BUBBLES - MIN_BUBBLES))

    # ── 2. 凸包缺陷度（形状越不规则越高）────────────────────────────────
    # 用每个泡泡边缘采样 8 个点来近似覆盖区域
    sample_pts = [
        (x + r * math.cos(a * math.pi / 4), y + r * math.sin(a * math.pi / 4))
        for x, y, r in placed for a in range(8)
    ]
    hull = _convex_hull(sample_pts)
    hull_area = _polygon_area(hull)
    if hull_area < 1.0:
        return 0.0

    circles_area = sum(math.pi * r * r for _, _, r in placed)
    defect = max(0.0, 1.0 - circles_area / hull_area)
    convexity_score = min(1.0, defect * 2.8)

    # ── 3. 核心遮蔽率（40-70% 保护为最佳）────────────────────────────────
    N_RAYS = 36
    blocked = 0
    for k in range(N_RAYS):
        ray_angle = k * math.tau / N_RAYS
        for x, y, r in placed[1:]:
            dx, dy = x - cx, y - cy
            d = math.hypot(dx, dy)
            if d < 1e-6: continue
            bubble_angle = math.atan2(dy, dx)
            diff = abs(math.atan2(math.sin(ray_angle - bubble_angle),
                                  math.cos(ray_angle - bubble_angle)))
            half_arc = math.asin(min(1.0, r / d)) if d > r else math.pi
            if diff < half_arc:
                blocked += 1
                break
    protection = blocked / N_RAYS
    # 目标 55%，±25% 内满分
    core_score = max(0.0, 1.0 - abs(protection - 0.55) / 0.30)

    # ── 4. 质心均衡（泡泡不能全堆一侧）──────────────────────────────────
    xs = [x for x, y, r in placed[1:]]
    ys = [y for x, y, r in placed[1:]]
    centroid_d = math.hypot(sum(xs)/len(xs), sum(ys)/len(ys))
    balance_score = max(0.0, 1.0 - centroid_d / (cr * 2.5))

    # ── 5. 径向多样性（泡泡在不同距离层）────────────────────────────────
    dists = [math.hypot(x - cx, y - cy) for x, y, r in placed[1:]]
    avg_d = sum(dists) / len(dists)
    if avg_d > 0:
        std_d = math.sqrt(sum((d - avg_d)**2 for d in dists) / len(dists))
        radial_score = min(1.0, std_d / avg_d)
    else:
        radial_score = 0.0

    # ── 6. 轻微打破对称（完全随机或完全对称都不有趣）────────────────────
    # 统计各象限泡泡数
    quadrants = [0, 0, 0, 0]
    for x, y, r in placed[1:]:
        q = (1 if x >= 0 else 0) + (2 if y >= 0 else 0)
        quadrants[q] += 1
    q_max, q_min = max(quadrants), min(quadrants)
    # 差值 1-3 之间最佳（各象限有泡泡但不均匀）
    sym_diff = q_max - q_min
    symmetry_score = 1.0 if 1 <= sym_diff <= 3 else max(0.0, 1.0 - abs(sym_diff - 2) / 3)

    return (
        count_score     * 0.15 +
        convexity_score * 0.30 +
        core_score      * 0.25 +
        balance_score   * 0.15 +
        radial_score    * 0.10 +
        symmetry_score  * 0.05
    )


# ─── GA 操作 ─────────────────────────────────────────────────────────────────
def random_genome() -> BossGenome:
    core_r = random.uniform(CORE_RADIUS_MIN, CORE_RADIUS_MAX)
    archetype = random.randint(0, 3)
    if archetype == 0:
        n = random.randint(MIN_BUBBLES - 1, min(11, MAX_BUBBLES - 1))
    elif archetype == 1:
        n = random.randint(11, MAX_BUBBLES - 1)
    elif archetype == 2:
        n = random.randint(9, min(15, MAX_BUBBLES - 1))
    else:
        n = random.randint(MIN_BUBBLES - 1, MAX_BUBBLES - 1)

    sats = []
    for i in range(n):
        if archetype == 0:
            parent_idx = 0 if random.random() < 0.65 else random.randint(0, i)
            angle = (random.randint(0, 5) * math.tau / 6.0) + random.uniform(-0.25, 0.25)
        elif archetype == 1:
            parent_idx = max(0, i - random.randint(0, min(2, i)))
            angle = random.choice([0.0, math.pi]) + random.uniform(-0.5, 0.5)
        elif archetype == 2:
            parent_idx = int(random.random() * random.random() * (i + 1))
            angle = (random.randint(0, 7) * math.tau / 8.0) + random.uniform(-0.5, 0.5)
        else:
            parent_idx = random.randint(0, i)
            angle = random.uniform(0, math.tau)
        sats.append(BubbleGene(
            parent_idx=parent_idx,
            angle=angle,
            radius=random.uniform(SM_R_MIN, SM_R_MAX),
            hp=random.randint(1, 3),
        ))

    behavior = random_behavior()
    return BossGenome(core_r, sats, **behavior)


def tournament_select(pop, fits) -> BossGenome:
    candidates = random.sample(range(len(pop)), TOURNAMENT_SIZE)
    best = max(candidates, key=lambda i: fits[i])
    return pop[best].clone()


def crossover(a: BossGenome, b: BossGenome) -> BossGenome:
    if random.random() > CROSSOVER_RATE:
        return a.clone()
    n = min(len(a.satellites), len(b.satellites))
    if n < 2:
        return a.clone()
    pt = random.randint(1, n - 1)
    sats = a.satellites[:pt] + b.satellites[pt:]
    # 修复越界 parent_idx
    for i, g in enumerate(sats):
        sats[i] = BubbleGene(min(g.parent_idx, i), g.angle, g.radius, g.hp)
    return BossGenome(
        (a.core_radius + b.core_radius) / 2.0,
        sats,
        initial_heading=random.choice([a.initial_heading, b.initial_heading]),
        turn_rate=(a.turn_rate + b.turn_rate) / 2.0,
        preferred_range=(a.preferred_range + b.preferred_range) / 2.0,
        orbit_weight=(a.orbit_weight + b.orbit_weight) / 2.0,
        orbit_dir=random.choice([a.orbit_dir, b.orbit_dir]),
        aim_lead=(a.aim_lead + b.aim_lead) / 2.0,
    )


def mutate(g: BossGenome) -> BossGenome:
    g = g.clone()
    if random.random() < MUTATION_RATE:
        g.core_radius = max(CORE_RADIUS_MIN, min(CORE_RADIUS_MAX,
                            g.core_radius + random.gauss(0, 4.0)))
    if random.random() < MUTATION_RATE:
        g.initial_heading = (g.initial_heading + random.gauss(0, 0.8)) % (2 * math.pi)
    if random.random() < MUTATION_RATE:
        g.turn_rate = max(0.6, min(4.5, g.turn_rate + random.gauss(0, 0.35)))
    if random.random() < MUTATION_RATE:
        g.preferred_range = max(90.0, min(320.0, g.preferred_range + random.gauss(0, 28.0)))
    if random.random() < MUTATION_RATE:
        g.orbit_weight = max(0.05, min(1.2, g.orbit_weight + random.gauss(0, 0.12)))
    if random.random() < MUTATION_RATE * 0.4:
        g.orbit_dir *= -1
    if random.random() < MUTATION_RATE:
        g.aim_lead = max(0.0, min(0.7, g.aim_lead + random.gauss(0, 0.08)))
    for i, b in enumerate(g.satellites):
        if random.random() < MUTATION_RATE:
            b.angle += random.gauss(0, 0.45)
        if random.random() < MUTATION_RATE:
            b.radius = max(SM_R_MIN, min(SM_R_MAX,
                           b.radius + random.gauss(0, 2.5)))
        if random.random() < MUTATION_RATE * 0.4:
            b.parent_idx = random.randint(0, i)
        if random.random() < MUTATION_RATE * 0.25:
            b.hp = random.randint(1, 2)
    # 增删泡泡
    if random.random() < MUTATION_RATE and len(g.satellites) < MAX_BUBBLES - 1:
        i = len(g.satellites)
        g.satellites.append(BubbleGene(
            random.randint(0, i), random.uniform(0, math.tau),
            random.uniform(SM_R_MIN, SM_R_MAX), random.randint(1, 2)
        ))
    elif random.random() < MUTATION_RATE * 0.4 and len(g.satellites) > MIN_BUBBLES - 1:
        idx = random.randint(0, len(g.satellites) - 1)
        g.satellites.pop(idx)
        for j, b in enumerate(g.satellites):
            b.parent_idx = min(b.parent_idx, j)
    return g


def genome_signature(genome: BossGenome) -> Tuple[float, ...]:
    placed = decode(genome)
    if len(placed) <= 1:
        return (0.0,) * 8

    dists = [math.hypot(x, y) for x, y, _ in placed[1:]]
    radii = [r for _, _, r in placed[1:]]
    quadrants = [0, 0, 0, 0]
    for x, y, _ in placed[1:]:
        q = (1 if x >= 0 else 0) + (2 if y >= 0 else 0)
        quadrants[q] += 1

    count_norm = len(placed) / MAX_BUBBLES
    core_norm = genome.core_radius / CORE_RADIUS_MAX
    avg_dist = sum(dists) / len(dists)
    dist_norm = avg_dist / (avg_dist + genome.core_radius + 1e-6)
    spread = math.sqrt(sum((d - avg_dist) ** 2 for d in dists) / len(dists)) / (avg_dist + 1e-6)
    avg_radius = sum(radii) / len(radii) / SM_R_MAX
    quadrant_skew = (max(quadrants) - min(quadrants)) / max(1, len(placed) - 1)
    behavior_mix = abs(genome.orbit_weight - 0.5) + genome.aim_lead + genome.turn_rate / 5.0
    return (
        count_norm,
        core_norm,
        dist_norm,
        spread,
        avg_radius,
        quadrant_skew,
        behavior_mix,
        0.0 if genome.orbit_dir < 0 else 1.0,
    )


def signature_distance(a: Tuple[float, ...], b: Tuple[float, ...]) -> float:
    return sum(abs(x - y) for x, y in zip(a, b)) / len(a)


def select_diverse_top(pop: List[BossGenome], fits: List[float], keep_n: int) -> List[dict]:
    sorted_idx = sorted(range(len(fits)), key=lambda i: -fits[i])
    results = []
    signatures: List[Tuple[float, ...]] = []

    for idx in sorted_idx:
        if len(results) >= keep_n:
            break
        g = pop[idx]
        placed = decode(g)
        if len(placed) < MIN_BUBBLES:
            continue

        sig = genome_signature(g)
        min_dist = min((signature_distance(sig, old) for old in signatures), default=999.0)
        if signatures and min_dist < 0.12 and len(results) < keep_n - 3:
            continue

        results.append({
            "fitness": round(fits[idx], 4),
            "valid_bubbles": len(placed),
            "genome": g.to_dict(),
        })
        signatures.append(sig)

    for idx in sorted_idx:
        if len(results) >= keep_n:
            break
        g = pop[idx]
        placed = decode(g)
        if len(placed) >= MIN_BUBBLES:
            results.append({
                "fitness": round(fits[idx], 4),
                "valid_bubbles": len(placed),
                "genome": g.to_dict(),
            })

    return results[:keep_n]


# ─── 主进化循环 ───────────────────────────────────────────────────────────────
def run_ga(seed: int = 42) -> List[dict]:
    random.seed(seed)
    pop = [random_genome() for _ in range(POPULATION_SIZE)]
    best_ever_f = -1.0
    best_ever_g = None

    print(f"种群大小={POPULATION_SIZE}  迭代={GENERATIONS}  精英={ELITE_FRACTION:.0%}")
    print("-" * 60)

    for gen in range(GENERATIONS):
        fits = [fitness(g) for g in pop]

        best_idx = max(range(len(fits)), key=lambda i: fits[i])
        best_f   = fits[best_idx]
        avg_f    = sum(fits) / len(fits)

        if best_f > best_ever_f:
            best_ever_f = best_f
            best_ever_g = pop[best_idx].clone()

        if gen % 30 == 0 or gen == GENERATIONS - 1:
            n_valid = len(decode(pop[best_idx]))
            print(f"  Gen {gen:4d}  best={best_f:.4f}  avg={avg_f:.4f}"
                  f"  all-time={best_ever_f:.4f}  bubbles={n_valid}")

        # 精英保留
        n_elite = max(1, int(POPULATION_SIZE * ELITE_FRACTION))
        sorted_idx = sorted(range(len(fits)), key=lambda i: -fits[i])
        new_pop = [pop[i].clone() for i in sorted_idx[:n_elite]]

        while len(new_pop) < POPULATION_SIZE:
            child = crossover(tournament_select(pop, fits),
                              tournament_select(pop, fits))
            new_pop.append(mutate(child))
        pop = new_pop

    # 最终评估，按 fitness + 多样性选 top-N
    fits = [fitness(g) for g in pop]
    results = select_diverse_top(pop, fits, KEEP_TOP_N)

    print("-" * 60)
    print(f"完成！保存 {len(results)} 个 Boss 形态 → {OUTPUT_FILE}")
    print(f"最高适应度: {best_ever_f:.4f}")
    return results


# ─── 可视化预览（需要 matplotlib）────────────────────────────────────────────
def preview(results: List[dict], n: int = 8):
    try:
        import matplotlib.pyplot as plt
        import matplotlib.patches as patches
    except ImportError:
        print("[preview] 需要安装 matplotlib：pip install matplotlib")
        return

    n = min(n, len(results))
    cols = 4
    rows = math.ceil(n / cols)
    fig, axes = plt.subplots(rows, cols, figsize=(cols * 4, rows * 4))
    axes = axes.flatten() if hasattr(axes, 'flatten') else [axes]

    for ax_i, entry in enumerate(results[:n]):
        ax = axes[ax_i]
        g = BossGenome.from_dict(entry["genome"])
        placed = decode(g)

        # 计算炮塔：取距离核心最远的 2-3 个
        dists = [(math.hypot(x, y), idx) for idx, (x, y, r) in enumerate(placed[1:], 1)]
        dists.sort(reverse=True)
        turret_idxs = {d[1] for d in dists[:3]}

        for idx, (x, y, r) in enumerate(placed):
            is_core = (idx == 0)
            color = "#ff6100" if is_core else "#ff3838"
            alpha = 0.88 if is_core else 0.72
            circle = plt.Circle((x, y), r, color=color, alpha=alpha)
            ax.add_patch(circle)
            # 炮塔标记
            if idx in turret_idxs:
                ax.plot(x, y, 'y*', markersize=10)

        # 标出核心
        cx, cy, cr = placed[0]
        ax.plot(cx, cy, 'ko', markersize=5)

        max_ext = max((math.hypot(x, y) + r) for x, y, r in placed) + 10
        ax.set_xlim(-max_ext, max_ext)
        ax.set_ylim(-max_ext, max_ext)
        ax.set_aspect('equal')
        ax.set_title(f"#{ax_i+1}  fit={entry['fitness']:.3f}"
                     f"  n={entry['valid_bubbles']}", fontsize=9)
        ax.axis('off')

    for ax in axes[n:]:
        ax.axis('off')

    plt.suptitle("Evolved Boss Formations  (★ = turret)", fontsize=13)
    plt.tight_layout()
    plt.show()


# ─── 入口 ─────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    do_preview = "--preview" in sys.argv

    results = run_ga()

    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        json.dump(results, f, indent=2, ensure_ascii=False)

    if do_preview:
        preview(results)
