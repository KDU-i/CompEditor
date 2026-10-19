package p;
public class ExceptionMain {
    static class Nested { static void fail() { throw new IllegalStateException("fixture"); } }
    public static void main(String[] args) { Nested.fail(); }
}
