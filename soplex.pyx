# cython: embedsignature=True

from libc.stdlib cimport malloc, free
from cpython.exc cimport PyErr_CheckSignals


from decimal import Decimal
from fractions import Fraction

try:
    from sympy import Basic, Number
except:
    class Basic:
        pass
    Number = Basic

include "soplex_constants.pxi"

__version__ = "0.0.5"
__soplex_version__ = "%.2f.%d" % (SOPLEX_VERSION/100., SOPLEX_SUBVERSION)
__soplex_git_hash__ = getGitHash()

cpdef dict get_status_mapping():
    return {i.real: i.name for i in STATUS}

cdef Rational rationalize(number):
    cdef Rational r
    if isinstance(number, (int, Number, Decimal, Fraction)):
        r = Rational()
        r.readString(str(number).encode())
        return r
    elif isinstance(number, Basic):
        # TODO handle better
        return Rational(0)
    else:
        r = Rational()
        s = "%15g" % number
        s = s.encode()
        r.readString(s.strip())
        return r

cdef bool is_status_error(STATUS status) nogil:
    if status == OPTIMAL or status == INFEASIBLE or status == UNBOUNDED:
        return False
    return True


cdef rational_to_frac(Rational rational):
    return Fraction(rationalToString(rational))

cdef class Soplex:
    """cobra SoPlex solver object"""
    # Because we use the default constructor for soplex,
    # we can do this instead of self.soplex = new SoPlex() in
    # __cinit__() and del self.soplex in __dealloc__().
    cdef SoPlex soplex
    cdef VarStatus* row_basis
    cdef VarStatus* col_basis
    cdef readonly bool reset_basis
    cdef int _reset_basis_iter_cutoff

    cdef bool verbose(self):
        return self.soplex.intParam(VERBOSITY)

    cpdef int soplex_status(self):
        return self.soplex.status()

    def __dealloc__(self):
        if self.row_basis is not NULL:
            free(self.row_basis)
        if self.col_basis is not NULL:
            free(self.col_basis)

    def __init__(self, cobra_model=None):
        # set the default paramters

        # should sync automatically between Real and Rational
        self.soplex.setIntParam(SYNCMODE, SYNCMODE_AUTO)
        # set default solving parameters
        self.soplex.setIntParam(VERBOSITY, 0)
        self.soplex.setIntParam(ITERLIMIT, 2147483647)  # 2 ** 31 - 1
        self.soplex.setIntParam(SOLVEMODE, SOLVEMODE_RATIONAL)
        self.soplex.setRealParam(FEASTOL, 1e-20)
        self.soplex.setRealParam(OPTTOL, 1e-20)

        self._reset_basis_iter_cutoff = 10000
        self.reset_basis = False

        # create an LP from the cobra model
        if cobra_model is None:
            return
        cdef DSVectorRational vector
        cdef LPColRational col
        cdef Rational bound
        cdef int i, s
        cdef DSVectorReal r_vector = DSVectorReal(0)
        cdef int m = len(cobra_model.metabolites)
        cdef int n = len(cobra_model.reactions)
        # To get around lack of infinity in Rational, create bounds with Real
        # first, then convert to Rational
        for i in range(m):
            self.soplex.addRowReal(LPRowReal(0, r_vector, 0))
        for i, metabolite in enumerate(cobra_model.metabolites):
            self.change_constraint(i, metabolite._constraint_sense,
                                   metabolite._bound)
        for reaction in cobra_model.reactions:
            vector = DSVectorRational(len(reaction._metabolites))
            for metabolite, stoichiometry in reaction._metabolites.items():
                if isinstance(stoichiometry, Basic) and \
                        not isinstance(stoichiometry, Number):
                    continue
                vector.add(cobra_model.metabolites.index(metabolite.id),
                           rationalize(stoichiometry))
            col = LPColRational(rationalize(reaction.objective_coefficient),
                                vector,
                                rationalize(reaction.upper_bound),
                                rationalize(reaction.lower_bound))
            self.soplex.addColRational(col)

        # initialize the row and column basis
        with nogil:
            s = sizeof(VarStatus)
            self.row_basis = <VarStatus *>malloc(m * s)
            self.col_basis = <VarStatus *>malloc(n * s)
            for i in range(m):
                self.row_basis[i] = ON_UPPER
            for i in range(n):
                self.col_basis[i] = ON_UPPER
            self.soplex.getBasis(self.row_basis, self.col_basis)

 
    @classmethod
    def create_problem(cls, cobra_model, objective_sense="maximize"):
        problem = cls(cobra_model)
        problem.set_objective_sense(objective_sense)
        return problem

    cpdef set_objective_sense(self, objective_sense="maximize"):
        objective_sense = objective_sense.lower()
        if objective_sense == "maximize":
            self.soplex.setIntParam(OBJSENSE, OBJSENSE_MAXIMIZE)
        elif objective_sense == "minimize":
            self.soplex.setIntParam(OBJSENSE, OBJSENSE_MINIMIZE)

    cpdef change_variable_bounds(self, int index, lower_bound, upper_bound):
        self.soplex.changeLowerRational(index, rationalize(lower_bound))
        self.soplex.changeUpperRational(index, rationalize(upper_bound))

    cpdef change_variable_objective(self, int index, value):
        self.soplex.changeObjRational(index, rationalize(value))

    cpdef change_coefficient(self, int met_index, int rxn_index, value):
        self.soplex.changeElementRational(met_index, rxn_index,
                                          rationalize(value))

    cpdef change_constraint(self, int met_index, str constraint_sense, value):
        cdef Rational bound = rationalize(value)
        if constraint_sense == "E":
            self.soplex.changeLhsRational(met_index, bound)
            self.soplex.changeRhsRational(met_index, bound)
        elif constraint_sense == "L":
            self.soplex.changeLhsReal(met_index, -infinity)
            self.soplex.changeRhsRational(met_index, bound)
        elif constraint_sense == "G":
            self.soplex.changeLhsRational(met_index, bound)
            self.soplex.changeRhsReal(met_index, infinity)
        else:
            raise ValueError(
                "constraint sense %d (%s) not in {'E', 'G', 'L'}" %
                (met_index, constraint_sense))

    cpdef set_parameter(self, parameter_name, value):
        name_upper = parameter_name.upper()
        if parameter_name == "objective_sense":
            self.set_objective_sense(value)
        elif parameter_name == "verbose" or name_upper == "VERBOSITY":
            if value is True:
                self.soplex.setIntParam(VERBOSITY, 3)
            else:
                self.soplex.setIntParam(VERBOSITY, value)
        elif name_upper == "SOLVEMODE":
            self.soplex.setIntParam(SOLVEMODE, SOLVEMODE_VALUES[value.upper()]) 
        elif name_upper == "CHECKMODE":
            self.soplex.setIntParam(CHECKMODE, CHECKMODE_VALUES[value.upper()])
        elif name_upper == "FACTOR_UPDATE_MAX":
            self.soplex.setIntParam(FACTOR_UPDATE_MAX, int(value))
        elif name_upper == "ITERLIMIT":
            self.soplex.setIntParam(ITERLIMIT, int(value))
        elif name_upper == "REFLIMIT":
            self.soplex.setIntParam(REFLIMIT, int(value))
        elif name_upper == "STALLREFLIMIT":
            self.soplex.setIntParam(STALLREFLIMIT, int(value))
        elif name_upper == "RATFAC_MINSTALLS":
            self.soplex.setIntParam(RATFAC_MINSTALLS, int(value))
        elif parameter_name in IntParameters:
            raise NotImplementedError("todo implement " + parameter_name)
        # setRealParam section
        elif name_upper == "FEASTOL" or parameter_name == "tolerance_feasibility":
            self.soplex.setRealParam(FEASTOL, value)
        elif name_upper == "OPTTOL":
            self.soplex.setRealParam(OPTTOL, value)
        elif name_upper == "EPSILON_ZERO":
            self.soplex.setRealParam(EPSILON_ZERO, value)
        elif name_upper == "EPSILON_FACTORIZATION":
            self.soplex.setRealParam(EPSILON_FACTORIZATION, value)
        elif name_upper == "EPSILON_UPDATE":
            self.soplex.setRealParam(EPSILON_UPDATE, value)
        elif name_upper == "EPSILON_PIVOT":
            self.soplex.setRealParam(EPSILON_PIVOT, value)
        elif name_upper == "INFTY":
            self.soplex.setRealParam(INFTY, value)
        elif name_upper == "TIMELIMIT" or parameter_name == "time_limit":
            self.soplex.setRealParam(TIMELIMIT, value)
        elif name_upper == "OBJLIMIT_LOWER":
            self.soplex.setRealParam(OBJLIMIT_LOWER, value)
        elif name_upper == "OBJLIMIT_UPPER":
            self.soplex.setRealParam(OBJLIMIT_UPPER, value)
        elif name_upper == "FPFEASTOL":
            self.soplex.setRealParam(FPFEASTOL, value)
        elif name_upper == "FPOPTTOL":
            self.soplex.setRealParam(FPOPTTOL, value)
        elif name_upper == "MAXSCALEINCR":
            self.soplex.setRealParam(MAXSCALEINCR, value)
        elif name_upper == "LIFTMINVAL":
            self.soplex.setRealParam(LIFTMINVAL, value)
        elif name_upper == "LIFTMAXVAL":
            self.soplex.setRealParam(LIFTMAXVAL, value)
        elif name_upper == "SPARSITY_THRESHOLD":
            self.soplex.setRealParam(SPARSITY_THRESHOLD, value)
        elif name_upper == "RESET_BASIS_ITER_CUTOFF":
            self._reset_basis_iter_cutoff = value
        else:
            raise ValueError("Unknown parameter '%s'" % parameter_name)

    def solve_problem(self, **kwargs):
        cdef STATUS result
        if "objective_sense" in kwargs:
            self.set_objective_sense(kwargs.pop("objective_sense"))
        for key, value in kwargs.items():
            self.set_parameter(key, value)
        
        # try to solve with a set basis
        self.reset_basis = False
        cdef int iterlim = self.soplex.intParam(ITERLIMIT)
        cdef int new_iterlim
        if iterlim > 0:  # -1 iterlim means it's unlimited
            new_iterlim = min(self._reset_basis_iter_cutoff, iterlim)
        else:
            new_iterlim = self._reset_basis_iter_cutoff
        self.soplex.setIntParam(ITERLIMIT, new_iterlim)
        self.soplex.setBasis(self.row_basis, self.col_basis)
        with nogil:
            result = self.soplex.solve()
            self.soplex.setIntParam(ITERLIMIT, iterlim)  # reset iterlim
        PyErr_CheckSignals()
        if self.verbose():
            print(self.soplex.statisticString())

        # if it didn't solve with the set basis, try again
        with nogil:
            if is_status_error(result):
                self.reset_basis = True
                self.soplex.clearBasis()
                result = self.soplex.solve()
        if self.verbose():
            print(self.soplex.statisticString())

        # save the basis for next time
        if result == OPTIMAL:
            self.soplex.getBasis(self.row_basis, self.col_basis)
        return self.get_status()

    cpdef get_status(self):
        cdef int status = self.soplex.status()
        if status == OPTIMAL:
            return "optimal"
        elif status == INFEASIBLE:
            return "infeasible"
        else:
            mapping = get_status_mapping()
            status_str = mapping.get(status)
            return status_str if status_str is not None else "failed"

    cpdef get_objective_value(self, rational=False):
        if rational:
            return rational_to_frac(self.soplex.objValueRational())
        else:
            return self.soplex.objValueReal()

    cpdef format_solution(self, cobra_model):
        status = self.get_status()
        Solution = cobra_model.solution.__class__
        if status != "optimal":  # todo handle other possible
            return Solution(None, status=status)
        solution = Solution(self.get_objective_value(), status=status)
        cdef int i
        # get primals
        cdef int nCols = self.soplex.numColsReal()
        cdef DVectorReal x_vals = DVectorReal(nCols)
        self.soplex.getPrimalReal(x_vals)
        solution.x = [x_vals[i] for i in range(nCols)]
        solution.x_dict = {cobra_model.reactions[i].id: x_vals[i]
                           for i in range(nCols)}
        # get duals
        cdef int nRows = self.soplex.numRowsReal()
        cdef DVectorReal y_vals = DVectorReal(nRows)
        self.soplex.getDualReal(y_vals)
        solution.y = [y_vals[i] for i in range(nRows)]
        solution.y_dict = {cobra_model.metabolites[i].id: y_vals[i]
                           for i in range(nRows)}
        return solution

    @classmethod
    def solve(cls, cobra_model, **kwargs):
        problem = cls.create_problem(cobra_model)
        problem.solve_problem(**kwargs)
        solution = problem.format_solution(cobra_model)
        return solution

    cpdef clear_basis(self):
        IF False:
            for i in range(self.soplex.numRowsReal()):
                self.row_basis[i] = ON_UPPER
            for i in range(self.soplex.numColsReal()):
                self.col_basis[i] = ON_UPPER
            self.soplex.setBasis(self.row_basis, self.col_basis)
        self.soplex.clearBasis()

    @property
    def numRows(self):
        return self.soplex.numRowsReal()

    @property
    def numCols(self):
        return self.soplex.numColsReal()

    cpdef write(self, filename, state=True, rational=False):
        if state:
            if filename.endswith(b".lp"):
                filename = filename[:-3]
            if rational:
                self.soplex.writeStateRational(filename, NULL, NULL, True)
                return
            else:
                self.soplex.writeStateReal(filename, NULL, NULL, True)
                return
        if rational:
            return self.soplex.writeFileRational(filename)
        else:
            return self.soplex.writeFileReal(filename)

    @property
    def hasPrimal(self):
        return self.soplex.hasPrimal()

    @property
    def hasBasis(self):
        return self.soplex.hasBasis()

    @property
    def solveTime(self):
        return self.soplex.solveTime()

    @property
    def numIterations(self):
        return self.soplex.numIterations()

# wrappers for all the functions at the module level
create_problem = Soplex.create_problem
def set_objective_sense(lp, objective_sense="maximize"):
    return lp.set_objective_sense(lp, objective_sense=objective_sense)
cpdef change_variable_bounds(lp, int index, lower_bound, upper_bound):
    return lp.change_variable_bounds(index, lower_bound, upper_bound)
cpdef change_variable_objective(lp, int index, value):
    return lp.change_variable_objective(index, value)
cpdef change_coefficient(lp, int met_index, int rxn_index, value):
    return lp.change_coefficient(met_index, rxn_index, value)
cpdef change_constraint(lp, int met_index, str constraint_sense, value):
    return lp.change_constraint(met_index, constraint_sense, value)
cpdef set_parameter(lp, parameter_name, value):
    return lp.set_parameter(parameter_name, value)
def solve_problem(lp, **kwargs):
    return lp.solve_problem(**kwargs)
cpdef get_status(lp):
    return lp.get_status()
cpdef get_objective_value(lp):
    return lp.get_objective_value()
cpdef format_solution(lp, cobra_model):
    return lp.format_solution(cobra_model)
solve = Soplex.solve
