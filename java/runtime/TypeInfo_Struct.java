//
// Copyright (C) 2001-2004 The University of Melbourne.
// This file may only be copied under the terms of the GNU Library General
// Public License - see the file COPYING.LIB in the Mercury distribution.
//

package mercury.runtime;

public class TypeInfo_Struct extends PseudoTypeInfo {

	public TypeCtorInfo_Struct type_ctor;
	public PseudoTypeInfo args[];

	public TypeInfo_Struct(TypeCtorInfo_Struct tc)
	{
		type_ctor = tc;
	}

    	// raw constructor
	public TypeInfo_Struct(TypeCtorInfo_Struct tc, PseudoTypeInfo... as)
	{
		type_ctor = tc;
		args = as;
	}

	// copy constructor
	// XXX Rather than invoking this constructor, and allocating a new
	//     type_info object on the heap, we should generate code which
	//     just copies the pointer,
	public TypeInfo_Struct(TypeInfo_Struct ti)
	{
		type_ctor = ti.type_ctor;
		args = ti.args;
	}

	// XXX "as" should have type PseudoTypeInfo[],
	//     but mlds_to_java.m uses Object[]
	//     because init_array/1 does not store the type.
	public TypeInfo_Struct(TypeCtorInfo_Struct tc, int arity, Object[] as)
	{
		assert arity == as.length;

		type_ctor = tc;
		args = new PseudoTypeInfo[as.length];
		for (int i = 0; i < as.length; i++) {
			args[i] = (PseudoTypeInfo) as[i];
		}
	}

	// XXX "as" should have type PseudoTypeInfo[],
	//     but mlds_to_java.m uses Object[]
	//     because init_array/1 does not store the type.
	public TypeInfo_Struct(TypeCtorInfo_Struct tc, Object[] as)
	{
		type_ctor = tc;
		args = new PseudoTypeInfo[as.length];
		for (int i = 0; i < as.length; i++) {
			args[i] = (PseudoTypeInfo) as[i];
		}
	}

	// XXX untested guess
	public TypeInfo_Struct(TypeInfo_Struct ti, int arity, Object... as)
	{
		this(ti.type_ctor, arity, as);
	}

	// XXX untested guess
	public TypeInfo_Struct(TypeInfo_Struct ti, Object... as)
	{
		this(ti.type_ctor, as);
	}

	// XXX a temp hack just to get things to run
	public TypeInfo_Struct(java.lang.Object obj)
	{
		if (obj instanceof TypeInfo_Struct) {
			TypeInfo_Struct ti = (TypeInfo_Struct) obj;
			type_ctor = ti.type_ctor;
			args = ti.args;
		} else {
			throw new java.lang.Error("TypeInfo_Struct(Object)");
		}
	}

		// XXX this should be renamed `equals'
	public boolean unify(TypeInfo_Struct ti) {
		if (this == ti) {
			return true;
		}

		if (type_ctor.unify(ti.type_ctor) == false) {
			return false;
		}

		if (args == null || ti.args == null) {
			if (args == null && ti.args == null) {
				return true;
			}
			return false;
		}

		for (int i = 0; i < args.length || i < ti.args.length; i++) {
			if (i == args.length || i == ti.args.length) {
				return false;
			}
			if (args[i].unify(ti.args[i]) == false) {
				return false;
			}
		}
		return true;
	}
}
