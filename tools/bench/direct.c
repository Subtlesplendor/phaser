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

#include <float.h>
#include <math.h>
#include <stdint.h>

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

/*
 * Independent scalar one-loop value baselines.
 *
 * Status values are intentionally local to the benchmark ABI:
 *
 *   0  success
 *   1  non-finite input or result
 *   2  the fixed-size Jacobi iteration did not converge
 *
 * A negative eigenvalue is successful and contributes the positive imaginary
 * part of the principal logarithm. An exact zero contributes exact zero before
 * a logarithm is formed.
 */

typedef struct {
    double re;
    double im;
} phaser_bench_complex64;

enum {
    PHASER_BENCH_STATUS_OK = 0,
    PHASER_BENCH_STATUS_NON_FINITE = 1,
    PHASER_BENCH_STATUS_NONCONVERGENT = 2
};

static int one_loop_sum(
    const double *eigenvalues,
    unsigned dimension,
    double scale,
    phaser_bench_complex64 *result
) {
    if (!isfinite(scale) || scale <= 0.0) {
        return PHASER_BENCH_STATUS_NON_FINITE;
    }

    phaser_bench_complex64 total = {0.0, 0.0};
    const double normalization =
        64.0 * 3.141592653589793238462643383279502884 *
        3.141592653589793238462643383279502884;
    for (unsigned index = 0; index < dimension; ++index) {
        const double eigenvalue = eigenvalues[index];
        if (!isfinite(eigenvalue)) {
            return PHASER_BENCH_STATUS_NON_FINITE;
        }
        if (eigenvalue == 0.0) {
            continue;
        }

        const double square = eigenvalue * eigenvalue;
        const double logarithm = log(fabs(eigenvalue) / (scale * scale));
        total.re += square * (logarithm - 1.5) / normalization;
        if (eigenvalue < 0.0) {
            total.im += square /
                (64.0 * 3.141592653589793238462643383279502884);
        }
    }
    if (!isfinite(total.re) || !isfinite(total.im)) {
        return PHASER_BENCH_STATUS_NON_FINITE;
    }
    *result = total;
    return PHASER_BENCH_STATUS_OK;
}

static int one_loop_1x1_expression(
    const double *parameters,
    const double *background,
    double scale,
    phaser_bench_complex64 *result
) {
    const double lambda = parameters[0];
    const double m2 = parameters[1];
    const double phi = background[0];
    const double eigenvalue = m2 + (0.5 * lambda) * phi * phi;
    return one_loop_sum(&eigenvalue, 1, scale, result);
}

int phaser_bench_one_loop_1x1_value(
    const double *parameters,
    const double *background,
    double scale,
    phaser_bench_complex64 *result
) {
    return one_loop_1x1_expression(parameters, background, scale, result);
}

void phaser_bench_one_loop_1x1_value_batch(
    const double *restrict parameters,
    const double *restrict backgrounds,
    double scale,
    unsigned long long point_count,
    phaser_bench_complex64 *restrict results,
    unsigned char *restrict statuses
) {
    for (unsigned long long point = 0; point < point_count; ++point) {
        statuses[point] = (unsigned char)one_loop_1x1_expression(
            parameters,
            backgrounds + point,
            scale,
            results + point
        );
    }
}

static int one_loop_2x2_expression(
    const double *parameters,
    const double *background,
    double scale,
    phaser_bench_complex64 *result
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
    const double h = background[0];
    const double s = background[1];
    const double h_squared = h * h;
    const double s_squared = s * s;

    const double hh =
        m_h2 + a * h + b * s +
        (0.5 * lh) * h_squared +
        (l3 * h) * s +
        (0.5 * l2) * s_squared;
    const double hs =
        m_hs2 + b * h + c * s +
        (0.5 * l3) * h_squared +
        (l2 * h) * s +
        (0.5 * l1) * s_squared;
    const double ss =
        m_s2 + c * h + d * s +
        (0.5 * l2) * h_squared +
        (l1 * h) * s +
        (0.5 * ls) * s_squared;
    if (!isfinite(hh) || !isfinite(hs) || !isfinite(ss)) {
        return PHASER_BENCH_STATUS_NON_FINITE;
    }

    const double middle = 0.5 * (hh + ss);
    const double radius = hypot(0.5 * (hh - ss), hs);
    const double eigenvalues[2] = {middle - radius, middle + radius};
    return one_loop_sum(eigenvalues, 2, scale, result);
}

int phaser_bench_one_loop_2x2_value(
    const double *parameters,
    const double *background,
    double scale,
    phaser_bench_complex64 *result
) {
    return one_loop_2x2_expression(parameters, background, scale, result);
}

void phaser_bench_one_loop_2x2_value_batch(
    const double *restrict parameters,
    const double *restrict backgrounds,
    double scale,
    unsigned long long point_count,
    phaser_bench_complex64 *restrict results,
    unsigned char *restrict statuses
) {
    for (unsigned long long point = 0; point < point_count; ++point) {
        statuses[point] = (unsigned char)one_loop_2x2_expression(
            parameters,
            backgrounds + 2 * point,
            scale,
            results + point
        );
    }
}

static void jacobi_rotate_3x3(double matrix[3][3], unsigned p, unsigned q) {
    const double apq = matrix[p][q];
    if (apq == 0.0) {
        return;
    }

    const double app = matrix[p][p];
    const double aqq = matrix[q][q];
    const double tau = (aqq - app) / (2.0 * apq);
    const double tangent = (tau >= 0.0 ? 1.0 : -1.0) /
        (fabs(tau) + hypot(1.0, tau));
    const double cosine = 1.0 / hypot(1.0, tangent);
    const double sine = tangent * cosine;

    for (unsigned index = 0; index < 3; ++index) {
        if (index == p || index == q) {
            continue;
        }
        const double aip = matrix[index][p];
        const double aiq = matrix[index][q];
        const double next_p = cosine * aip - sine * aiq;
        const double next_q = sine * aip + cosine * aiq;
        matrix[index][p] = next_p;
        matrix[p][index] = next_p;
        matrix[index][q] = next_q;
        matrix[q][index] = next_q;
    }

    matrix[p][p] =
        cosine * cosine * app -
        2.0 * sine * cosine * apq +
        sine * sine * aqq;
    matrix[q][q] =
        sine * sine * app +
        2.0 * sine * cosine * apq +
        cosine * cosine * aqq;
    matrix[p][q] = 0.0;
    matrix[q][p] = 0.0;
}

static int eigenvalues_3x3(double matrix[3][3], double values[3]) {
    double maximum = 0.0;
    for (unsigned row = 0; row < 3; ++row) {
        for (unsigned column = row; column < 3; ++column) {
            if (!isfinite(matrix[row][column])) {
                return PHASER_BENCH_STATUS_NON_FINITE;
            }
            maximum = fmax(maximum, fabs(matrix[row][column]));
        }
    }
    if (maximum == 0.0) {
        values[0] = 0.0;
        values[1] = 0.0;
        values[2] = 0.0;
        return PHASER_BENCH_STATUS_OK;
    }

    int exponent = 0;
    (void)frexp(maximum, &exponent);
    for (unsigned row = 0; row < 3; ++row) {
        for (unsigned column = 0; column < 3; ++column) {
            matrix[row][column] = ldexp(matrix[row][column], -exponent);
        }
    }

    int converged = 0;
    for (unsigned sweep = 0; sweep < 24; ++sweep) {
        jacobi_rotate_3x3(matrix, 0, 1);
        jacobi_rotate_3x3(matrix, 0, 2);
        jacobi_rotate_3x3(matrix, 1, 2);
        const double off_diagonal =
            fabs(matrix[0][1]) +
            fabs(matrix[0][2]) +
            fabs(matrix[1][2]);
        const double diagonal =
            fabs(matrix[0][0]) +
            fabs(matrix[1][1]) +
            fabs(matrix[2][2]);
        if (off_diagonal <= 16.0 * DBL_EPSILON * diagonal) {
            converged = 1;
            break;
        }
    }
    if (!converged) {
        return PHASER_BENCH_STATUS_NONCONVERGENT;
    }

    values[0] = ldexp(matrix[0][0], exponent);
    values[1] = ldexp(matrix[1][1], exponent);
    values[2] = ldexp(matrix[2][2], exponent);
    for (unsigned left = 1; left < 3; ++left) {
        const double value = values[left];
        unsigned position = left;
        while (position > 0 && values[position - 1] > value) {
            values[position] = values[position - 1];
            --position;
        }
        values[position] = value;
    }
    return PHASER_BENCH_STATUS_OK;
}

static int one_loop_3x3_expression(
    const double *parameters,
    const double *background,
    double scale,
    phaser_bench_complex64 *result
) {
    const double b = background[0];
    double matrix[3][3] = {
        {parameters[0] * b, parameters[1] * b, parameters[2] * b},
        {parameters[1] * b, parameters[3] * b, parameters[4] * b},
        {parameters[2] * b, parameters[4] * b, parameters[5] * b}
    };
    double eigenvalues[3];
    const int solved = eigenvalues_3x3(matrix, eigenvalues);
    if (solved != PHASER_BENCH_STATUS_OK) {
        return solved;
    }
    return one_loop_sum(eigenvalues, 3, scale, result);
}

int phaser_bench_one_loop_3x3_value(
    const double *parameters,
    const double *background,
    double scale,
    phaser_bench_complex64 *result
) {
    return one_loop_3x3_expression(parameters, background, scale, result);
}

void phaser_bench_one_loop_3x3_value_batch(
    const double *restrict parameters,
    const double *restrict backgrounds,
    double scale,
    unsigned long long point_count,
    phaser_bench_complex64 *restrict results,
    unsigned char *restrict statuses
) {
    for (unsigned long long point = 0; point < point_count; ++point) {
        statuses[point] = (unsigned char)one_loop_3x3_expression(
            parameters,
            backgrounds + point,
            scale,
            results + point
        );
    }
}

/*
 * Dependency carrier for latency measurements.
 *
 * The low mantissa bits are mapped into a bounded interval without calling a
 * transcendental function. Phaser and direct C both call this exact function,
 * and the benchmark reports its cost separately.
 */
double phaser_bench_dependency_carrier(
    double value,
    double base,
    double span
) {
    union {
        double floating;
        uint64_t bits;
    } representation = {value};
    const uint64_t fraction_bits =
        representation.bits & UINT64_C(0x000fffffffffffff);
    const double fraction =
        (double)fraction_bits * (1.0 / 4503599627370496.0);
    return base + span * fraction;
}
