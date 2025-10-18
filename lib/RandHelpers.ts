import seedrandom from "seedrandom";

export class PRNG {
  private rng: seedrandom.PRNG;
  public cycle: number;

  constructor(seed: string | number, cycle: number = 0) {
    this.rng = seedrandom(seed.toString());
    this.cycle = 0;
    for (let i = 0; i < cycle; i++) {
      this.rng();
    }
  }

  randAlphaNum(length: number): string {
    const chars =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    let result = "";
    for (let i = 0; i < length; i++) {
      result += chars.charAt(Math.floor(this.next() * chars.length));
    }
    return result;
  }

  next(): number {
    this.cycle++;
    return this.rng();
  }

  draw<T>(s: T[]): T {
    return this.shuffle(s)[0];
  }

  coinToss(prob: number = 0.5): boolean {
    return this.next() < prob;
  }

  dice(sides: number = 6): number {
    return this.getRandomInt(1, sides);
  }

  rollMultipleDice(rolls: number, sides: number = 6): number[] {
    const results: number[] = [];
    for (let i = 0; i < rolls; i++) {
      results.push(this.dice(sides));
    }
    return results;
  }

  randomElement<T>(arr: readonly T[]): T {
    return arr[Math.floor(this.next() * arr.length)];
  }

  randomBoolean(): boolean {
    return this.next() < 0.5;
  }

  getRandomFloat(min: number, max: number): number {
    return this.next() * (max - min) + min;
  }

  getRandomInt(min: number, max: number): number {
    return Math.floor(this.next() * (max - min + 1)) + min;
  }

  getRandomFloatNormal(min: number, max: number): number {
    const u1 = this.next();
    const u2 = this.next();
    const standardNormal =
      Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2);
    const mean = (max + min) / 2;
    const stdDev = (max - min) / 6;
    return standardNormal * stdDev + mean;
  }

  getRandomIntNormal(min: number, max: number): number {
    const floatNormal = this.getRandomFloatNormal(min, max);
    return Math.round(floatNormal);
  }

  weightedRandomKey<T>(obj: { [T: string]: number }): T {
    const keys = Object.keys(obj);
    const total = keys.reduce((sum, k) => sum + obj[k], 0);
    let r = this.next() * total;
    for (const k of keys) {
      r -= obj[k];
      if (r <= 0) return k as T;
    }
    return keys[0] as T;
  }

  shuffle<T>(array: readonly T[]): T[] {
    const result = [...array];
    for (let i = result.length - 1; i > 0; i--) {
      const j = Math.floor(this.next() * (i + 1));
      [result[i], result[j]] = [result[j], result[i]];
    }
    return result;
  }
}
