/*
 * parameter.c - parameter support
 *
 *   Copyright (c) 2000-2003 Shiro Kawai, All rights reserved.
 * 
 *   Redistribution and use in source and binary forms, with or without
 *   modification, are permitted provided that the following conditions
 *   are met:
 * 
 *   1. Redistributions of source code must retain the above copyright
 *      notice, this list of conditions and the following disclaimer.
 *
 *   2. Redistributions in binary form must reproduce the above copyright
 *      notice, this list of conditions and the following disclaimer in the
 *      documentation and/or other materials provided with the distribution.
 *
 *   3. Neither the name of the authors nor the names of its contributors
 *      may be used to endorse or promote products derived from this
 *      software without specific prior written permission.
 *
 *   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 *   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 *   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 *   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 *   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 *   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
 *   TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 *   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 *   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 *   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 *   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 *  $Id: parameter.c,v 1.6 2004-07-15 23:16:13 shirok Exp $
 */

#define LIBGAUCHE_BODY
#include "gauche.h"
#include "gauche/vm.h"

/*
 * Parameters keep thread-local states.   When a thread is created,
 * it inherits the set of parameters from its creator (except the
 * primordial thread).
 * Parameters have additional features, such as guard procedure
 * and observer callbacks.  They are implemented in Scheme level
 * (see lib/gauche/parameter.scm).  C level only provides low-level
 * accessor and modifier methods.
 *
 * It is debatable how to implement the inheritance semantics.  MzScheme
 * keeps user-defined parameters in a hash table, and uses
 * copy-on-write mechanism to delay the copy of the table.  It is nice,
 * but difficult to use in preemptive threads, for it requires lock of
 * the table every time even in reading parameters.  Guile uses the
 * vector (Guile calls them fluids, but it's semantically equivalent
 * to parameters), and eagerly copies the vector at the creation of the
 * thread.  Since thread creation in Gauche is already heavy anyway,
 * I take Guile's approach.
 */

#define PARAMETER_INIT_SIZE 64
#define PARAMETER_GROW      16

/* Every time a new parameter is created (in any thread), it is
 * given an unique ID in the process.  It prevents a thread from
 * dereferencnig a parameter created by an unrelated thread.
 */
static int next_parameter_id = 0;
ScmInternalMutex parameter_mutex;

/* Init table.  For primordial thread, base == NULL.  For non-primordial
 * thread, base is the current thread (this must be called from the
 * creator thread).
 */
void Scm_ParameterTableInit(ScmVMParameterTable *table,
                            ScmVM *base)
{
    int i;

    if (base) {
        table->vector = SCM_NEW_ARRAY(ScmObj, base->parameters.numAllocated);
        table->ids = SCM_NEW_ATOMIC2(int*, PARAMETER_INIT_SIZE*sizeof(int));
        table->numAllocated = base->parameters.numAllocated;
        table->numParameters = base->parameters.numParameters;
        for (i=0; i<table->numParameters; i++) {
            table->vector[i] = base->parameters.vector[i];
            table->ids[i] = base->parameters.ids[i];
        }
    } else {
        table->vector = SCM_NEW_ARRAY(ScmObj, PARAMETER_INIT_SIZE);
        table->ids = SCM_NEW_ATOMIC2(int*, PARAMETER_INIT_SIZE*sizeof(int));
        table->numParameters = 0;
        table->numAllocated = PARAMETER_INIT_SIZE;
    }
}

/*
 * Allocate new parameter slot
 */
int Scm_MakeParameterSlot(ScmVM *vm, int *newid)
{
    ScmVMParameterTable *p = &(vm->parameters);
    if (p->numParameters == p->numAllocated) {
        int i, newsiz = p->numAllocated + PARAMETER_GROW;
        ScmObj *newvec = SCM_NEW_ARRAY(ScmObj, newsiz);
        int *newids = SCM_NEW_ATOMIC2(int*, newsiz*sizeof(int));
        
        for (i=0; i<p->numParameters; i++) {
            newvec[i] = p->vector[i];
            p->vector[i] = SCM_FALSE; /*GC friendly*/
            newids[i] = p->ids[i];
        }
        p->vector = newvec;
        p->ids = newids;
        p->numAllocated += PARAMETER_GROW;
    }
    p->vector[p->numParameters] = SCM_UNDEFINED;
    SCM_INTERNAL_MUTEX_LOCK(parameter_mutex);
    p->ids[p->numParameters] = *newid = next_parameter_id++;
    SCM_INTERNAL_MUTEX_UNLOCK(parameter_mutex);
    return p->numParameters++;
}

/*
 * Accessor & modifier
 */

ScmObj Scm_ParameterRef(ScmVM *vm, int index, int id)
{
    ScmVMParameterTable *p = &(vm->parameters);
    SCM_ASSERT(index >= 0);
    if (index >= p->numParameters || p->ids[index] != id) {
        Scm_Error("the thread %S doesn't have parameter (%d:%d)",
                  vm, index, id);
    }
    SCM_ASSERT(p->vector[index] != NULL);
    return p->vector[index];
}

ScmObj Scm_ParameterSet(ScmVM *vm, int index, int id, ScmObj value)
{
    ScmVMParameterTable *p = &(vm->parameters);
    SCM_ASSERT(index >= 0);
    if (index >= p->numParameters || p->ids[index] != id) {
        Scm_Error("the thread %S doesn't have parameter (%d:%d)",
                  vm, index, id);
    }
    p->vector[index] = value;
    return value;
}

/*
 * Initialization
 */
void Scm__InitParameter(void)
{
    SCM_INTERNAL_MUTEX_INIT(parameter_mutex);
}
