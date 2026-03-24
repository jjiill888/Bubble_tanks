#!/usr/bin/env python3
"""
Tank Enemy Visual Genome Evolution
=================================
Generates a curated list of melee tank enemy silhouettes for tank_genomes.json.
"""

import copy
import json
import math
import random
from dataclasses import dataclass, field
from typing import List

POPULATION_SIZE = 80
GENERATIONS = 180
ELITE_COUNT = 10
TOURNAMENT_SIZE = 5
KEEP_TOP_N = 18
OUTPUT_FILE = "tank_genomes.json"

CORE_RADIUS_MIN = 24.0
CORE_RADIUS_MAX = 35.0
LOBE_RADIUS_MIN = 6.0
LOBE_RADIUS_MAX = 15.0
LOBE_COUNT_MIN = 2
LOBE_COUNT_MAX = 5

PALETTES = [
    ([0.92, 0.40, 0.16, 0.82], [0.64, 0.14, 0.10, 0.96]),
    ([0.94, 0.52, 0.12, 0.80], [0.66, 0.20, 0.08, 0.95]),
    ([0.88, 0.35, 0.22, 0.84], [0.58, 0.10, 0.14, 0.95]),
    ([0.98, 0.48, 0.20, 0.78], [0.70, 0.18, 0.10, 0.95]),
]


@dataclass
class LobeGene:
    angle: float
    distance: float
    radius: float

    def clone(self) -> "LobeGene":
        return copy.deepcopy(self)


@dataclass
class TankGenome:
    core_radius: float
    rim_thickness: float
    core_color: List[float]
    rim_color: List[float]
    nucleus_offset: List[float]
    nucleus_radius: float
    highlight_offset: List[float]
    highlight_radius: float
    lobes: List[LobeGene] = field(default_factory=list)

    def clone(self) -> "TankGenome":
        return copy.deepcopy(self)

    def to_dict(self, idx: int, score: float) -> dict:
        return {
            "id": idx,
            "fitness": round(score, 4),
            "genome": {
                "core_radius": round(self.core_radius, 2),
                "rim_thickness": round(self.rim_thickness, 2),
                "core_color": [round(v, 3) for v in self.core_color],
                "rim_color": [round(v, 3) for v in self.rim_color],
                "nucleus_offset": [round(v, 2) for v in self.nucleus_offset],
                "nucleus_radius": round(self.nucleus_radius, 2),
                "highlight_offset": [round(v, 2) for v in self.highlight_offset],
                "highlight_radius": round(self.highlight_radius, 2),
                "lobes": [
                    {
                        "angle": round(lobe.angle % math.tau, 4),
                        "distance": round(lobe.distance, 2),
                        "radius": round(lobe.radius, 2),
                    }
                    for lobe in self.lobes
                ],
            },
        }


def random_palette():
    return copy.deepcopy(random.choice(PALETTES))


def random_genome() -> TankGenome:
    core_color, rim_color = random_palette()
    core_radius = random.uniform(CORE_RADIUS_MIN, CORE_RADIUS_MAX)
    lobe_count = random.randint(LOBE_COUNT_MIN, LOBE_COUNT_MAX)
    lobes = []
    base_step = math.tau / lobe_count
    for index in range(lobe_count):
        angle = index * base_step + random.uniform(-0.45, 0.45)
        distance = random.uniform(core_radius * 0.25, core_radius * 0.78)
        radius = random.uniform(LOBE_RADIUS_MIN, LOBE_RADIUS_MAX)
        lobes.append(LobeGene(angle, distance, radius))
    return TankGenome(
        core_radius=core_radius,
        rim_thickness=random.uniform(1.8, 3.2),
        core_color=core_color,
        rim_color=rim_color,
        nucleus_offset=[random.uniform(-10.0, -3.0), random.uniform(-9.0, -2.0)],
        nucleus_radius=random.uniform(7.0, 10.5),
        highlight_offset=[random.uniform(8.0, 13.0), random.uniform(4.0, 10.0)],
        highlight_radius=random.uniform(5.0, 8.5),
        lobes=lobes,
    )


def fitness(genome: TankGenome) -> float:
    lobe_count = len(genome.lobes)
    count_score = 1.0 - abs(lobe_count - 4) / 3.0

    distances = [l.distance for l in genome.lobes]
    radii = [l.radius for l in genome.lobes]
    if not distances or not radii:
        return 0.0

    dist_mean = sum(distances) / len(distances)
    rad_mean = sum(radii) / len(radii)
    dist_var = sum((d - dist_mean) ** 2 for d in distances) / len(distances)
    rad_var = sum((r - rad_mean) ** 2 for r in radii) / len(radii)
    irregularity_score = min(1.0, (math.sqrt(dist_var) + math.sqrt(rad_var)) / 8.0)

    sorted_angles = sorted(l.angle % math.tau for l in genome.lobes)
    gaps = []
    for idx, angle in enumerate(sorted_angles):
        next_angle = sorted_angles[(idx + 1) % len(sorted_angles)]
        gap = (next_angle - angle) % math.tau
        gaps.append(gap)
    angle_balance = 1.0 - min(1.0, sum(abs(g - math.tau / len(sorted_angles)) for g in gaps) / math.tau)

    max_extent = max(l.distance + l.radius for l in genome.lobes)
    compactness_score = max(0.0, 1.0 - abs(max_extent - genome.core_radius * 1.45) / (genome.core_radius * 0.9))

    forward_weight = sum(max(0.0, math.cos(l.angle)) * l.radius for l in genome.lobes)
    rear_weight = sum(max(0.0, -math.cos(l.angle)) * l.radius for l in genome.lobes)
    bruiser_bias = 1.0 - min(1.0, abs(forward_weight - rear_weight * 1.2) / 18.0)

    return max(0.0, count_score) * 0.22 + irregularity_score * 0.24 + angle_balance * 0.18 + compactness_score * 0.18 + bruiser_bias * 0.18


def crossover(a: TankGenome, b: TankGenome) -> TankGenome:
    child = a.clone()
    child.core_radius = (a.core_radius + b.core_radius) * 0.5
    child.rim_thickness = random.choice([a.rim_thickness, b.rim_thickness])
    child.core_color = copy.deepcopy(random.choice([a.core_color, b.core_color]))
    child.rim_color = copy.deepcopy(random.choice([a.rim_color, b.rim_color]))
    child.nucleus_offset = [random.choice([a.nucleus_offset[0], b.nucleus_offset[0]]), random.choice([a.nucleus_offset[1], b.nucleus_offset[1]])]
    child.nucleus_radius = (a.nucleus_radius + b.nucleus_radius) * 0.5
    child.highlight_offset = [random.choice([a.highlight_offset[0], b.highlight_offset[0]]), random.choice([a.highlight_offset[1], b.highlight_offset[1]])]
    child.highlight_radius = (a.highlight_radius + b.highlight_radius) * 0.5
    child.lobes = []
    max_lobes = max(len(a.lobes), len(b.lobes))
    for idx in range(max_lobes):
        source = a if random.random() < 0.5 else b
        other = b if source is a else a
        if idx < len(source.lobes):
            base = source.lobes[idx].clone()
            if idx < len(other.lobes):
                base.angle = (base.angle + other.lobes[idx].angle) * 0.5
                base.distance = (base.distance + other.lobes[idx].distance) * 0.5
                base.radius = (base.radius + other.lobes[idx].radius) * 0.5
            child.lobes.append(base)
    return child


def mutate(genome: TankGenome) -> None:
    if random.random() < 0.5:
        genome.core_radius = max(CORE_RADIUS_MIN, min(CORE_RADIUS_MAX, genome.core_radius + random.uniform(-2.5, 2.5)))
    if random.random() < 0.35:
        genome.rim_thickness = max(1.5, min(3.5, genome.rim_thickness + random.uniform(-0.4, 0.4)))
    if random.random() < 0.25 and len(genome.lobes) < LOBE_COUNT_MAX:
        genome.lobes.append(LobeGene(random.uniform(0.0, math.tau), random.uniform(genome.core_radius * 0.25, genome.core_radius * 0.8), random.uniform(LOBE_RADIUS_MIN, LOBE_RADIUS_MAX)))
    if random.random() < 0.2 and len(genome.lobes) > LOBE_COUNT_MIN:
        genome.lobes.pop(random.randrange(len(genome.lobes)))
    for lobe in genome.lobes:
        if random.random() < 0.6:
            lobe.angle = (lobe.angle + random.uniform(-0.45, 0.45)) % math.tau
        if random.random() < 0.6:
            lobe.distance = max(3.0, min(genome.core_radius * 0.9, lobe.distance + random.uniform(-3.0, 3.0)))
        if random.random() < 0.6:
            lobe.radius = max(LOBE_RADIUS_MIN, min(LOBE_RADIUS_MAX, lobe.radius + random.uniform(-2.0, 2.0)))


def tournament(population: List[TankGenome]) -> TankGenome:
    sample = random.sample(population, TOURNAMENT_SIZE)
    return max(sample, key=fitness)


def evolve() -> List[dict]:
    population = [random_genome() for _ in range(POPULATION_SIZE)]
    for _ in range(GENERATIONS):
        ranked = sorted(population, key=fitness, reverse=True)
        next_population = [ranked[i].clone() for i in range(ELITE_COUNT)]
        while len(next_population) < POPULATION_SIZE:
            parent_a = tournament(ranked)
            parent_b = tournament(ranked)
            child = crossover(parent_a, parent_b)
            mutate(child)
            next_population.append(child)
        population = next_population
    ranked = sorted(population, key=fitness, reverse=True)[:KEEP_TOP_N]
    return [genome.to_dict(idx + 1, fitness(genome)) for idx, genome in enumerate(ranked)]


def main() -> None:
    entries = evolve()
    with open(OUTPUT_FILE, "w", encoding="utf-8") as handle:
        json.dump(entries, handle, ensure_ascii=False, indent=2)
    print(f"Saved {len(entries)} tank genomes to {OUTPUT_FILE}")


if __name__ == "__main__":
    main()