import java.util.Set;
import javax.annotation.processing.*;
import javax.lang.model.SourceVersion;
import javax.lang.model.element.TypeElement;
@SupportedAnnotationTypes("*")
public class Processor extends AbstractProcessor {
    public SourceVersion getSupportedSourceVersion() { return SourceVersion.latestSupported(); }
    public boolean process(Set<? extends TypeElement> annotations, RoundEnvironment environment) {
        try { java.nio.file.Files.writeString(java.nio.file.Path.of("processor-ran"), "must never run"); }
        catch (java.io.IOException error) { throw new RuntimeException(error); }
        return false;
    }
}
