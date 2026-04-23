use std::collections::HashMap;

fn main() {
    let mut m: HashMap<&str, u32> = HashMap::new();
    m.insert("riscv64", 64);
    m.insert("musl", 1);
    for (k, v) in &m {
        println!("{k} = {v}");
    }
    assert_eq!(m.values().sum::<u32>(), 65);
    println!("ok");
}
