/*
 * Direct numerical expressions for the benchmark models.
 *
 * These functions deliberately bypass Phaser's value graph and instruction
 * interpreter. The pinned Zig toolchain compiles this file with strict
 * floating-point contraction disabled, so it introduces no external compiler
 * dependency and does not silently adopt relaxed arithmetic.
 *
 * Parameter offsets are the models' canonical lexicographic parameter order,
 * which is also the packed order exposed by their benchmark bindings.
 */

#if defined(__clang__) || defined(__GNUC__)
#define PHASER_BENCH_NOINLINE __attribute__((noinline))
#else
#define PHASER_BENCH_NOINLINE
#endif

static double absolute(double value) {
    return value < 0.0 ? -value : value;
}

static inline double phi4_expression(
    const double *parameters,
    const double *background
) {
    const double lambda = parameters[0];
    const double m2 = parameters[1];
    const double omega = parameters[2];
    const double phi = background[0];
    const double phi_squared = phi * phi;
    const double phi_fourth = phi_squared * phi_squared;

    return omega +
        (0.5 * m2) * phi_squared +
        ((1.0 / 24.0) * lambda) * phi_fourth;
}

PHASER_BENCH_NOINLINE double phaser_bench_phi4_value(
    const double *parameters,
    const double *background
) {
    return phi4_expression(parameters, background);
}

void phaser_bench_phi4_value_batch(
    const double *restrict parameters,
    const double *restrict backgrounds,
    unsigned long long point_count,
    double *restrict values
) {
    for (unsigned long long point = 0; point < point_count; ++point) {
        values[point] = phi4_expression(parameters, backgrounds + point);
    }
}

double phaser_bench_phi4_magnitude(
    const double *parameters,
    const double *background
) {
    const double lambda = parameters[0];
    const double m2 = parameters[1];
    const double omega = parameters[2];
    const double phi = background[0];
    const double phi_squared = phi * phi;
    const double phi_fourth = phi_squared * phi_squared;

    return absolute(omega) +
        absolute((0.5 * m2) * phi_squared) +
        absolute(((1.0 / 24.0) * lambda) * phi_fourth);
}

static inline double multi_scalar_expression(
    const double *parameters,
    const double *background
) {
    const double a = parameters[0];
    const double b = parameters[1];
    const double c = parameters[2];
    const double d = parameters[3];
    const double l1 = parameters[4];
    const double l2 = parameters[5];
    const double l3 = parameters[6];
    const double lh = parameters[7];
    const double ls = parameters[8];
    const double m_h2 = parameters[9];
    const double m_hs2 = parameters[10];
    const double m_s2 = parameters[11];
    const double omega = parameters[12];
    const double t_h = parameters[13];
    const double t_s = parameters[14];
    const double h = background[0];
    const double s = background[1];
    const double h_squared = h * h;
    const double s_squared = s * s;
    const double h_cubed = h_squared * h;
    const double s_cubed = s_squared * s;
    const double h_fourth = h_squared * h_squared;
    const double s_fourth = s_squared * s_squared;

    return omega +
        t_h * h +
        t_s * s +
        (0.5 * m_h2) * h_squared +
        (m_hs2 * h) * s +
        (0.5 * m_s2) * s_squared +
        ((1.0 / 6.0) * a) * h_cubed +
        (((0.5 * b) * h_squared) * s) +
        (((0.5 * c) * h) * s_squared) +
        ((1.0 / 6.0) * d) * s_cubed +
        ((1.0 / 24.0) * lh) * h_fourth +
        (((1.0 / 6.0) * l3) * h_cubed) * s +
        (((0.25 * l2) * h_squared) * s_squared) +
        (((1.0 / 6.0) * l1) * h) * s_cubed +
        ((1.0 / 24.0) * ls) * s_fourth;
}

PHASER_BENCH_NOINLINE double phaser_bench_multi_scalar_value(
    const double *parameters,
    const double *background
) {
    return multi_scalar_expression(parameters, background);
}

void phaser_bench_multi_scalar_value_batch(
    const double *restrict parameters,
    const double *restrict backgrounds,
    unsigned long long point_count,
    double *restrict values
) {
    for (unsigned long long point = 0; point < point_count; ++point) {
        values[point] = multi_scalar_expression(
            parameters,
            backgrounds + 2 * point
        );
    }
}

double phaser_bench_multi_scalar_magnitude(
    const double *parameters,
    const double *background
) {
    const double a = parameters[0];
    const double b = parameters[1];
    const double c = parameters[2];
    const double d = parameters[3];
    const double l1 = parameters[4];
    const double l2 = parameters[5];
    const double l3 = parameters[6];
    const double lh = parameters[7];
    const double ls = parameters[8];
    const double m_h2 = parameters[9];
    const double m_hs2 = parameters[10];
    const double m_s2 = parameters[11];
    const double omega = parameters[12];
    const double t_h = parameters[13];
    const double t_s = parameters[14];
    const double h = background[0];
    const double s = background[1];
    const double h_squared = h * h;
    const double s_squared = s * s;
    const double h_cubed = h_squared * h;
    const double s_cubed = s_squared * s;
    const double h_fourth = h_squared * h_squared;
    const double s_fourth = s_squared * s_squared;

    return absolute(omega) +
        absolute(t_h * h) +
        absolute(t_s * s) +
        absolute((0.5 * m_h2) * h_squared) +
        absolute((m_hs2 * h) * s) +
        absolute((0.5 * m_s2) * s_squared) +
        absolute(((1.0 / 6.0) * a) * h_cubed) +
        absolute(((0.5 * b) * h_squared) * s) +
        absolute(((0.5 * c) * h) * s_squared) +
        absolute(((1.0 / 6.0) * d) * s_cubed) +
        absolute(((1.0 / 24.0) * lh) * h_fourth) +
        absolute((((1.0 / 6.0) * l3) * h_cubed) * s) +
        absolute(((0.25 * l2) * h_squared) * s_squared) +
        absolute((((1.0 / 6.0) * l1) * h) * s_cubed) +
        absolute(((1.0 / 24.0) * ls) * s_fourth);
}
