fn main() {
    val b = 6
    
    if b > 10 {
        printf("true\n")
    }
    else if b > 5 {
        printf("maybe\n")
    }
    else {
        printf("false\n")
    }
    
    printf("Done\n")
}

extern fn printf(format: string)

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
                        name: 'b',
                        type: i32,
                        value: <int> 6,
                    },
                    If {
                        cond: <bool> Binary {
                            lhs: <i32> Identifier('b'),
                            rhs: <i32> Cast {
                                value: <int> 10,
                            },
                            op: gt,
                        },
                        body: Block {
                            stmts: [
                                FnCall {
                                    callee: <fn(string): void> Identifier('printf'),
                                    args: [
                                        <string> "true\n",
                                    ],
                                    return_type: void,
                                },
                            ],
                        },
                        else: If {
                            cond: <bool> Binary {
                                lhs: <i32> Identifier('b'),
                                rhs: <i32> Cast {
                                    value: <int> 5,
                                },
                                op: gt,
                            },
                            body: Block {
                                stmts: [
                                    FnCall {
                                        callee: <fn(string): void> Identifier('printf'),
                                        args: [
                                            <string> "maybe\n",
                                        ],
                                        return_type: void,
                                    },
                                ],
                            },
                            else: Block {
                                stmts: [
                                    FnCall {
                                        callee: <fn(string): void> Identifier('printf'),
                                        args: [
                                            <string> "false\n",
                                        ],
                                        return_type: void,
                                    },
                                ],
                            },
                        },
                    },
                    FnCall {
                        callee: <fn(string): void> Identifier('printf'),
                        args: [
                            <string> "Done\n",
                        ],
                        return_type: void,
                    },
                ],
            },
        },
        FnDecl {
            is_extern: true,
            is_public: false,
            name: 'printf',
            params: [
                FnParam {
                    name: 'format',
                    type: string,
                },
            ],
        },
    ],
}
***/