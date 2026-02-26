fn main() {
    var x = 10
    x = 20
    x += 3
    x *= 4
    x -= 5
    x /= 6
    x %= 7
    x = foo()
}

fn foo(): i32 {
    return 0
}

/***
Module {
    fn_decls: [
        FnDecl {
            is_extern: false,
            is_public: false,
            name: 'main',
            params: [],
            body: Block {
                stmts: [
                    VarDecl {
                        name: 'x',
                        type: i32,
                        value: <int> 10,
                    },
                    Assignment {
                        lhs: <i32> Identifier('x'),
                        rhs: <int> 20,
                        op: eq,
                    },
                    Assignment {
                        lhs: <i32> Identifier('x'),
                        rhs: <int> 3,
                        op: plus_eq,
                    },
                    Assignment {
                        lhs: <i32> Identifier('x'),
                        rhs: <int> 4,
                        op: mul_eq,
                    },
                    Assignment {
                        lhs: <i32> Identifier('x'),
                        rhs: <int> 5,
                        op: minus_eq,
                    },
                    Assignment {
                        lhs: <i32> Identifier('x'),
                        rhs: <int> 6,
                        op: div_eq,
                    },
                    Assignment {
                        lhs: <i32> Identifier('x'),
                        rhs: <int> 7,
                        op: mod_eq,
                    },
                    Assignment {
                        lhs: <i32> Identifier('x'),
                        rhs: <i32> FnCall {
                            callee: <fn(): i32> Identifier('foo'),
                            args: [],
                            return_type: i32,
                        },
                        op: eq,
                    },
                ],
            },
        },
        FnDecl {
            is_extern: false,
            is_public: false,
            name: 'foo',
            params: [],
            body: Block {
                stmts: [
                    Return {
                        value: <int> 0,
                    },
                ],
            },
        },
    ],
}
***/