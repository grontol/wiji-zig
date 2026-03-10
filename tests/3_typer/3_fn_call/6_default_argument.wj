fn main() {
    foo(10, 20, 30)
}

fn foo(x: i32, y: i32, z = 10) {
    
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
                    FnCall {
                        callee: <fn(i32, i32, i32): void> Identifier('foo'),
                        args: [
                            <int> 10,
                            <int> 20,
                            <int> 30,
                        ],
                        return_type: void,
                    },
                ],
            },
        },
        FnDecl {
            is_extern: false,
            is_public: false,
            name: 'foo',
            params: [
                FnParam {
                    name: 'x',
                    type: i32,
                },
                FnParam {
                    name: 'y',
                    type: i32,
                },
                FnParam {
                    name: 'z',
                    type: i32,
                    default_value: <int> 10,
                },
            ],
            body: Block {
                stmts: [],
            },
        },
    ],
}
***/