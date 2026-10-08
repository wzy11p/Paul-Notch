/* Synthetic signing fixture only; never accesses the GUI, network, or user data. */
int main(void) {
#ifdef SECOND_BUILD
    return 2;
#else
    return 1;
#endif
}
