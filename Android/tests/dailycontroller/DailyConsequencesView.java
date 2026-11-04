package local.studyplanner;
/** Test-only widget boundary. No rendering claim is made. */
final class DailyConsequencesView {
    final MainActivity app;
    DailyConsequencesView(MainActivity app){this.app=app;}
    void render(Object panel){app.render();}
}
